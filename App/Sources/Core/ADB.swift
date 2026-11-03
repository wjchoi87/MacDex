import Foundation

/// 번들 adb 래퍼 — 기기 감시/조회/무선 페어링/파일 전송.
/// 정책: 모든 adb 호출은 번들 adb(Binaries.adb)로. 시스템 adb 서버와 버전이 같으면
///   서버를 재시작하지 않고 공유한다(35.0.2 기준).
enum ADB {

    private static let env = Binaries.processEnvironment

    // MARK: 기기 목록

    /// `adb devices` 1회 조회.
    static func listDevices() async throws -> [Device] {
        let result = try await ProcessRunner.run(Binaries.adb, arguments: ["devices"], environment: env)
        guard result.succeeded else { throw ADBError.failure(result.output) }
        return parseDeviceLines(result.stdout)
    }

    /// `adb track-devices` 장기 실행 — 연결/해제 이벤트를 스냅샷으로 전달.
    /* 프로토콜(변경 전 인식 실패 원인): 스트림이 "4자리 hex 길이 + 페이로드" 프레임 반복이다.
       페이로드는 "serial\tstate\n..." 전체 목록 스냅샷(비면 기기 0대).
       이전 정책: 라인 단위 파싱 → 첫 시리얼이 프리픽스에 오염되고 해제 감지 불가.
       변경 후 정책: 바이트 스트리밍에서 프레임을 조립해 매 이벤트 전체 스냅샷으로 대체. */
    static func trackDevices(onUpdate: @escaping @Sendable ([Device]) -> Void) async throws -> StreamingProcess {
        final class FrameBuffer: @unchecked Sendable {
            var buffer = Data()
            let lock = NSLock()

            /// 완성된 프레임의 페이로드를 모두 반환(없으면 빈 배열).
            func drainCompletedPayloads() -> [Data] {
                var payloads: [Data] = []
                lock.lock()
                defer { lock.unlock() }
                while buffer.count >= 4 {
                    guard let header = String(data: buffer.prefix(4), encoding: .utf8),
                          let length = Int(header, radix: 16) else {
                        // 프로토콜 깨짐 — 버퍼 리셋(다음 프레임 동기화는 서버가 이어서 보냄)
                        buffer.removeAll()
                        break
                    }
                    guard buffer.count >= 4 + length else { break }
                    let payload = buffer.subdata(in: 4..<(4 + length))
                    buffer.removeSubrange(0..<(4 + length))
                    payloads.append(payload)
                }
                return payloads
            }
        }
        let frames = FrameBuffer()
        let process = StreamingProcess()
        try process.startByteStream(executable: Binaries.adb, arguments: ["track-devices"], environment: env) { byte in
            frames.lock.lock()
            frames.buffer.append(byte)
            frames.lock.unlock()

            for payload in frames.drainCompletedPayloads() {
                // 페이로드 = 전체 스냅샷: 파싱 결과로 상태를 완전 대체한다
                var devices: [Device] = []
                let text = String(data: payload, encoding: .utf8) ?? ""
                for line in text.split(separator: "\n") {
                    let parts = line.split(separator: "\t", maxSplits: 2).map(String.init)
                    guard parts.count >= 2 else { continue }
                    devices.append(Device(serial: parts[0].trimmingCharacters(in: .whitespaces),
                                          state: DeviceState(rawState: parts[1])))
                }
                onUpdate(devices.sorted { $0.serial < $1.serial })
            }
        }
        return process
    }

    static func parseDeviceLines(_ output: String) -> [Device] {
        var devices: [Device] = []
        let lines = output.split(separator: "\n").dropFirst() // "List of devices attached" 헤더 제거
        for line in lines {
            let parts = line.split(separator: "\t", maxSplits: 2).map(String.init)
            guard parts.count >= 2 else { continue }
            devices.append(Device(serial: parts[0].trimmingCharacters(in: .whitespaces),
                                  state: DeviceState(rawState: parts[1])))
        }
        return devices
    }

    // MARK: 기기 상세 정보

    /// 기기 상세를 채운다. 실패해도 기존 값 유지(부분 실패 허용 정책).
    static func fillDeviceDetails(_ device: Device) async -> Device {
        var d = device
        // 마커 프리픽스로 파싱 — getprop 빈 값/줄바꿈 변형에 강하게.
        let propsCmd = """
        echo "MANUFACTURER:$(getprop ro.product.manufacturer)"; \
        echo "BRAND:$(getprop ro.product.brand)"; \
        echo "MODEL:$(getprop ro.product.model)"; \
        echo "RELEASE:$(getprop ro.build.version.release)"; \
        echo "SDK:$(getprop ro.build.version.sdk)"; \
        echo "SIZE:$(wm size | head -1 | cut -d' ' -f3)"
        """
        if let out = try? await shell(serial: device.serial, propsCmd), device.state == .online {
            for line in out.split(separator: "\n") {
                let parts = line.split(separator: ":", maxSplits: 1).map(String.init)
                guard parts.count == 2 else { continue }
                let value = parts[1].trimmingCharacters(in: .whitespaces)
                switch parts[0] {
                case "MANUFACTURER": d.manufacturer = value.isEmpty ? nil : value
                case "BRAND": d.brand = value.isEmpty ? nil : value
                case "MODEL": d.model = value.isEmpty ? nil : value
                case "RELEASE": d.androidVersion = value.isEmpty ? nil : value
                case "SDK": d.sdkInt = Int(value)
                case "SIZE": d.screenSize = value.isEmpty ? nil : value
                default: break
                }
            }
        }
        if let battery = try? await battery(serial: device.serial) {
            d.batteryLevel = battery.level
            d.isCharging = battery.charging
        }
        return d
    }

    static func battery(serial: String) async throws -> (level: Int?, charging: Bool?) {
        let out = try await shell(serial: serial, "dumpsys battery")
        var level: Int?
        var charging: Bool?
        for line in out.split(separator: "\n") {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("level:"), let v = Int(t.dropFirst("level:".count).trimmingCharacters(in: .whitespaces)) {
                level = v
            }
            if t.hasPrefix("status:"), let v = Int(t.dropFirst("status:".count).trimmingCharacters(in: .whitespaces)) {
                charging = (v == 2 || v == 5)  // 2:충전중, 5:만충전
            }
        }
        return (level, charging)
    }

    // MARK: 셸

    static func shell(serial: String, _ command: String) async throws -> String {
        let result = try await ProcessRunner.run(
            Binaries.adb,
            arguments: ["-s", serial, "shell", command],
            environment: env
        )
        guard result.succeeded else { throw ADBError.failure(result.output) }
        return result.stdout
    }

    // MARK: 무선 연결

    /// Android 11+ 무선 디버깅 페어링(6자리 코드).
    static func pair(host: String, code: String) async throws -> String {
        let result = try await ProcessRunner.run(
            Binaries.adb, arguments: ["pair", host, code], environment: env
        )
        // adb pair는 성공해도 exit code가 0이 아닌 케이스가 있어 출력 문구로 판정한다.
        let output = result.output
        if output.contains("Successfully paired") || output.contains("successful") {
            return output
        }
        throw ADBError.failure(output)
    }

    static func connect(host: String) async throws -> String {
        let result = try await ProcessRunner.run(
            Binaries.adb, arguments: ["connect", host], environment: env
        )
        let output = result.output
        if output.contains("connected") && !output.contains("cannot connect") {
            return output
        }
        throw ADBError.failure(output)
    }

    static func disconnect(serial: String) async throws {
        _ = try? await ProcessRunner.run(Binaries.adb, arguments: ["disconnect", serial], environment: env)
    }

    /// USB로 연결된 기기를 TCP(5555) 모드로 전환하고 무선 주소를 돌려준다.
    /* 변경 전 정책: shell에서 setprop + adbd 직접 재시작 → USB 연결이 끊기는 부작용.
       변경 후 정책: 정식 `adb tcpip 5555`로 전환(안전한 공식 경로) 후 무선 connect.
       이유: adbd 재시작을 adb 클라이언트가 관리하므로 상태 일관성이 보장됨. */
    static func enableWireless(serial: String) async throws -> String {
        let out = try await shell(serial: serial, "ip -f inet addr show wlan0")
        // "inet 192.168.1.10/24 brd ..." 파싱
        guard let range = out.range(of: #"inet\s+(\d+\.\d+\.\d+\.\d+)"#, options: .regularExpression) else {
            throw ADBError.failure("Wi-Fi IP를 찾을 수 없습니다. 폰이 Wi-Fi에 연결되어 있는지 확인하세요.\n" + out)
        }
        let ip = out[range].split(separator: " ")[1].map(String.init)
        let host = "\(ip):5555"
        let switchResult = try await ProcessRunner.run(
            Binaries.adb, arguments: ["-s", serial, "tcpip", "5555"], environment: env
        )
        guard switchResult.succeeded else { throw ADBError.failure(switchResult.output) }
        // adbd가 TCP로 재시작될 때까지 잠시 대기 후 무선 연결
        try await Task.sleep(for: .seconds(2))
        _ = try await connect(host: host)
        return host
    }

    /// mDNS로 발견된 adb 서비스 목록.
    static func mdnsServices() async throws -> [MdnsService] {
        let result = try? await ProcessRunner.run(Binaries.adb, arguments: ["mdns", "services"], environment: env)
        guard let output = result?.stdout else { return [] }
        // 예: "adb-_adb-tls-connect._tcp      _tcp   192.168.0.10:12345"
        var services: [MdnsService] = []
        for line in output.split(separator: "\n").dropFirst(2) {
            let cols = line.split(separator: " ").map(String.init)
            guard cols.count >= 3 else { continue }
            let kind = cols[0]
            let address = cols[cols.count - 1]
            guard address.contains(":") else { continue }
            let name: String
            if kind.contains("pairing") {
                name = "페어링 대기중 (\(address))"
            } else {
                name = "무선 디버깅 (\(address))"
            }
            services.append(MdnsService(name: name, address: address))
        }
        return services
    }

    // MARK: 파일 전송

    static func push(serial: String, file: URL, destination: String = "/sdcard/Download/") async throws {
        // 경로에 공백이 있어도 안전하게 절대경로 배열로 전달
        let result = try await ProcessRunner.run(
            Binaries.adb,
            arguments: ["-s", serial, "push", file.path, destination],
            environment: env
        )
        guard result.succeeded else { throw ADBError.failure(result.output) }
    }

    // MARK: 설치된 앱

    /// 3rd-party 앱 목록: "package:<apk-path>=<package>" 형식.
    static func installedApps(serial: String, includeSystem: Bool = false) async throws -> [AndroidApp] {
        var args = ["pm", "list", "packages", "-f"]
        if !includeSystem { args.append("-3") }
        let out = try await shell(serial: serial, args.joined(separator: " "))
        var apps: [AndroidApp] = []
        for line in out.split(separator: "\n") {
            let entry = line.trimmingCharacters(in: .whitespaces)
            guard entry.hasPrefix("package:") else { continue }
            let body = entry.dropFirst("package:".count)
            if let eq = body.lastIndex(of: "=") {
                let apk = String(body[body.startIndex..<eq])
                let pkg = String(body[body.index(after: eq)...])
                apps.append(AndroidApp(package: pkg, apkPath: apk))
            }
        }
        return apps.sorted { $0.package < $1.package }
    }
}

// MARK: - 오류

enum ADBError: Error, LocalizedError {
    case failure(String)

    var errorDescription: String? {
        if case .failure(let message) = self {
            return message.count > 400 ? String(message.prefix(400)) + "…" : message
        }
        return nil
    }
}
