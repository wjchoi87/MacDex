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
    static func trackDevices(onUpdate: @escaping @Sendable ([Device]) -> Void,
                             onExit: (@Sendable (Int32) -> Void)? = nil) async throws -> StreamingProcess {
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
        try process.startByteStream(executable: Binaries.adb, arguments: ["track-devices"], environment: env, onByte: { byte in
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
        }, onExit: onExit)
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
        echo "SERIALNO:$(getprop ro.serialno)"; \
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
                case "SERIALNO": d.serialNo = value.isEmpty ? nil : value
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

    /* 무선 connect/pair는 대화형 액션이다 — 대상이 없으면 OS TCP 타임아웃까지
       오래 묶이므로 짧은 전용 타임아웃을 건다(기본 30초는 "무한 연결중"으로 느껴짐). */

    /// Android 11+ 무선 디버깅 페어링(6자리 코드).
    static func pair(host: String, code: String, timeout: TimeInterval = 12) async throws -> String {
        let result = try await ProcessRunner.run(
            Binaries.adb, arguments: ["pair", host, code], environment: env, timeout: timeout
        )
        // adb pair는 성공해도 exit code가 0이 아닌 케이스가 있어 출력 문구로 판정한다.
        let output = result.output
        if output.contains("Successfully paired") || output.contains("successful") {
            return output
        }
        throw ADBError.failure(output)
    }

    /// 무선 connect 최종 판정(실제 기기 상태 확인까지 끝난 결과).
    enum ConnectOutcome: Sendable, Equatable {
        case online                 // 'device' 상태 확인됨 — 바로 사용 가능
        case unauthorized           // 폰에서 디버깅 허용 대기(전송은 유지)
        case notAuthenticated       // 연결은 됐지만 인증/응답 없음 — 무선 디버깅 포트면 페어링 필요
        case refused                // 포트 닫힘(무선 디버깅 포트는 토글마다 바뀐다)
        case unreachable(String)    // No route to host 등 — 사설 LAN이면 서버의 로컬 네트워크 권한 의심
        case timedOut
        case failed(String)
    }

    /* 변경 전 정책: `adb connect` 출력에 "connected"가 있으면 성공으로 봤다.
       결함: adb는 이미 있는 전송이 offline이어도 "already connected to …"를 돌려주고,
       무선 디버깅(TLS) 포트는 페어링이 안 됐어도 "connected to"를 찍은 뒤 기기를 offline으로
       남긴다 → 앱은 "연결됨"을 띄우는데 실제로는 쓸 수 없다("한 번에 연결되는 적이 없다").
       변경 후 정책: ① 같은 주소의 비정상(offline 등) 잔류 전송을 먼저 disconnect ② connect
       ③ `adb devices`로 실제 상태가 device가 될 때까지 최대 6초 확인. 끝내 offline이면 잔류
       전송을 다시 정리하고 notAuthenticated, unauthorized면 폰 허용을 기다리도록 전송을 남긴다.
       영향 범위: IP 직접/자동발견 연결, USB→무선 전환, 자동 재접속 스윕, 연결 복구, CLI connect. */
    static func connectVerified(host: String, timeout: TimeInterval = 8) async -> ConnectOutcome {
        let outcome = await connectAttempt(host: host, timeout: timeout)
        switch outcome {
        case .online, .unauthorized:
            return outcome
        default:
            // 실패면 서버에 반쯤 열린 전송이 offline으로 남는다(실측: connect 타임아웃 후 클라이언트를
            // 죽여도 서버는 'host offline'을 유지) — 다음 시도가 "already connected"로 오판되지 않게 정리
            await disconnect(serial: host)
            return outcome
        }
    }

    private static func connectAttempt(host: String, timeout: TimeInterval) async -> ConnectOutcome {
        if let existing = try? await listDevices().first(where: { $0.serial == host }) {
            if existing.state == .online { return .online }
            await disconnect(serial: host)
        }

        let output: String
        do {
            output = try await ProcessRunner.run(
                Binaries.adb, arguments: ["connect", host], environment: env, timeout: timeout
            ).output
        } catch ProcessError.timedOut {
            return .timedOut
        } catch {
            return .failed(error.localizedDescription)
        }

        let text = output.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = text.lowercased()
        if lower.contains("connection refused") { return .refused }
        if lower.contains("no route to host") || lower.contains("network is unreachable")
            || lower.contains("host is down") {
            return .unreachable(text)
        }
        if lower.contains("timed out") { return .timedOut }
        if lower.contains("authenticate") { return .notAuthenticated }
        guard lower.contains("connected to"), !lower.contains("failed"), !lower.contains("cannot") else {
            return .failed(text)
        }

        // 출력만 믿지 않는다 — 실제 상태가 device가 될 때까지 확인
        var lastState: DeviceState?
        let deadline = Date().addingTimeInterval(6)
        while Date() < deadline {
            if let device = try? await listDevices().first(where: { $0.serial == host }) {
                lastState = device.state
                if device.state == .online { return .online }
            }
            try? await Task.sleep(for: .milliseconds(400))
        }
        return lastState == .unauthorized ? .unauthorized : .notAuthenticated
    }

    static func disconnect(serial: String) async {
        _ = try? await ProcessRunner.run(Binaries.adb, arguments: ["disconnect", serial],
                                         environment: env, timeout: 5)
    }

    /// adb 서버를 이 번들 adb로 재시작한다.
    /* 정책: kill-server는 같은 Mac의 다른 adb 클라이언트(Android Studio·터미널·scrcpy) 연결도
       끊는다. 그래서 '근거가 있을 때만' 호출한다 — 앱 자신은 LAN 기기에 TCP로 닿는데 서버만
       못 닿는 경우(서버를 띄운 프로세스에 로컬 네트워크 권한이 없음 — 실측: macOS는 폰 서비스를
       보는데 서버 mDNS는 0건). MacDroid가 띄운 서버는 MacDroid의 권한을 따른다. */
    static func restartServer() async {
        _ = try? await ProcessRunner.run(Binaries.adb, arguments: ["kill-server"], environment: env, timeout: 10)
        _ = try? await ProcessRunner.run(Binaries.adb, arguments: ["start-server"], environment: env, timeout: 15)
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
        // adbd가 TCP로 재시작될 때까지 잠시 대기 후 무선 연결 — 실제 device 상태까지 확인
        try await Task.sleep(for: .seconds(2))
        let outcome = await connectVerified(host: host)
        guard outcome == .online else {
            throw ADBError.failure("\(host) 연결 확인 실패(\(outcome)) — 폰과 맥이 같은 네트워크인지 확인하세요.")
        }
        return host
    }

    /// mDNS로 발견된 adb 서비스 목록.
    /* 파서 정책: adb mdns services의 컬럼 순서는 버전에 따라 다를 수 있어,
       각 줄에서 "ip:port" 패턴과 서비스 종류(pairing)를 정규식/문자열로 찾는다
       (고정 컬럼 파싱은 형식이 뒤집히면 전부 누락된다).
       중복 제거: 가상 네트워크 인터페이스(OrbStack/VM bridge·vmenet)가 많으면 같은
       서비스가 여러 번 반환된다(실측 8번) — address+pairing 기준으로 1개만 남긴다.
       주의: mDNS는 같은 LAN(멀티캐스트 도메인)에서만 동작 — VPN(Tailscale 등)이나
       다른 서브넷의 기기는 발견되지 않는다(실측). */
    static func mdnsServices() async throws -> [MdnsService] {
        let result = try? await ProcessRunner.run(Binaries.adb, arguments: ["mdns", "services"], environment: env)
        guard let output = result?.stdout else { return [] }
        var services: [MdnsService] = []
        var seen = Set<String>()
        for line in output.split(separator: "\n").dropFirst() {  // 헤더 "List of..." 제거
            guard let range = line.range(of: #"(\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}:\d+)"#,
                                         options: .regularExpression) else { continue }
            let address = String(line[range])
            let isPairing = line.lowercased().contains("pairing")
            let key = (isPairing ? "P" : "C") + address
            guard seen.insert(key).inserted else { continue }  // 인터페이스 중복 제거
            let name = (isPairing ? "페어링 대기중" : "무선 디버깅") + " (\(address))"
            services.append(MdnsService(name: name, address: address))
        }
        return services
    }

    // MARK: 절전 방지 (DeX 세션 동안 기기 잠금 방지)

    /* 정책: DeX/미러 세션이 살아 있는 동안 stay_on_while_plugged_in을 모든 전원(7)으로
       올려 기기가 잠들지 않게 한다. 물리 화면은 --turn-screen-off로 꺼둘 수 있고,
       꺼진 상태에서도 전원 연결 중에는 시스템이 잠들지 않는다(input 주입 가능 유지).
       배터리 구동 시 절전까지 막는 것은 안드로이드 정책상 불가 → key wakeup 보조.
       이전 값은 반환해 세션 종료 시 복구한다(사용자 설정 존중). */
    static func enableStayAwake(serial: String) async -> Int? {
        let previous = try? await shell(serial: serial, "settings get global stay_on_while_plugged_in")
        let prev = Int(previous?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "") ?? 0
        _ = try? await shell(serial: serial, "settings put global stay_on_while_plugged_in 7")
        return prev
    }

    static func restoreStayAwake(serial: String, previous: Int) async {
        _ = try? await shell(serial: serial, "settings put global stay_on_while_plugged_in \(previous)")
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

    static func pull(serial: String, remote: String, to local: URL) async throws {
        let result = try await ProcessRunner.run(
            Binaries.adb,
            arguments: ["-s", serial, "pull", remote, local.path],
            environment: env
        )
        guard result.succeeded else { throw ADBError.failure(result.output) }
    }

    // MARK: 화면/입력 (에이전트 CLI용)

    /// 현재 존재하는 디스플레이 id 집합 — scrcpy 가상디스플레이 감지(diff)용.
    static func displayIds(serial: String) async throws -> [Int] {
        let out = try await shell(serial: serial, "dumpsys display | grep -oE 'mDisplayId=[0-9]+'")
        return out.split(separator: "\n").compactMap {
            Int($0.trimmingCharacters(in: .whitespacesAndNewlines)
                .replacingOccurrences(of: "mDisplayId=", with: ""))
        }
    }

    /// 지정 디스플레이(기본: 물리 화면) 캡처 PNG 데이터.
    /* 정책: screencap -d는 빌드에 따라 논리 디스플레이 id를 받기도(SF 토큰만 받기도 한다
       — One UI 17 실측: 논리 id '10' 거부, SurfaceFlinger 토큰은 성공).
       따라서 논리 id로 시도 → PNG가 아니면 SF 토큰으로 대응해 재시도한다. */
    static func screenshotData(serial: String, displayId: Int?) async throws -> Data {
        func capture(_ idString: String) async throws -> Data {
            try await ProcessRunner.runData(
                Binaries.adb,
                arguments: ["-s", serial, "exec-out", "screencap", "-p", "-d", idString],
                environment: env
            )
        }
        if let displayId {
            if let data = try? await capture("\(displayId)"), data.isPNG {
                return data
            }
            if let token = try await surfaceFlingerToken(serial: serial, logicalId: displayId) {
                do {
                    let data = try await capture(token)
                    if data.isPNG { return data }
                } catch {}
            }
            throw ADBError.failure("디스플레이 \(displayId) 캡처 실패 (screencap -d)")
        }
        let data = try await ProcessRunner.runData(
            Binaries.adb, arguments: ["-s", serial, "exec-out", "screencap", "-p"], environment: env
        )
        guard data.isPNG else { throw ADBError.failure("screencap 실패 — 기기가 잠겨 있거나 화면이 꺼져 있을 수 있음") }
        return data
    }

    /// 논리 디스플레이 id에 대응하는 SurfaceFlinger 디스플레이 토큰.
    /// 대응 규칙: SF 가상디스플레이 토큰(덤프 등장순=생성순) ↔ 논리 가상 id(오름차순) 인덱스 페어.
    /// 토큰은 UInt64 범위라서(Int64 초과 — 실측) 문자열로 돌려준다.
    static func surfaceFlingerToken(serial: String, logicalId: Int) async throws -> String? {
        guard let logicals = try? await displayIds(serial: serial) else { return nil }
        let virtuals = logicals.filter { $0 != 0 }.sorted()
        guard let index = virtuals.firstIndex(of: logicalId) else { return nil }

        let sfOut = try await shell(
            serial: serial,
            "dumpsys SurfaceFlinger --display-id | grep 'Virtual display' | grep -oE '^Display [0-9]+'"
        )
        let tokens = sfOut.split(separator: "\n").compactMap { line -> UInt64? in
            let parts = line.split(separator: " ")
            guard parts.count >= 2, let n = UInt64(parts[1]) else { return nil }
            return n
        }
        guard index < tokens.count else { return nil }
        return String(tokens[index])
    }

    /// 입력 주입(tap/swipe/text/keyevent). displayId가 있으면 그 디스플레이로.
    static func input(serial: String, displayId: Int?, _ inputArgs: [String]) async throws {
        var shellArgs = ["-s", serial, "shell"]
        if let displayId { shellArgs += ["input", "-d", "\(displayId)"] } else { shellArgs += ["input"] }
        shellArgs += inputArgs
        let result = try await ProcessRunner.run(Binaries.adb, arguments: shellArgs, environment: env)
        guard result.succeeded else { throw ADBError.failure(result.output) }
    }

    /// adb shell 인자용 sh 인용 — adb가 인자들을 공백으로 합쳐 디바이스 sh가 다시 파싱하므로,
    /// 전체를 작은따옴표로 감싸고 내부 따옴표만 탈출한다(공백/특수문자 안전).
    static func shellQuoted(_ text: String) -> String {
        "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'"
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

extension Data {
    /// PNG 매직 헤더 여부 — screencap 실패 시 에러 텍스트가 stdout으로 오는 것을 구분.
    var isPNG: Bool {
        count > 8 && prefix(4).elementsEqual([0x89, 0x50, 0x4E, 0x47])
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
