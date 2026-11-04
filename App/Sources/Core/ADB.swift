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
            throw ADBError.failure(String(localized: "Wi-Fi IP를 찾을 수 없습니다. 폰이 Wi-Fi에 연결되어 있는지 확인하세요.\n") + out)
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
            throw ADBError.failure(String(localized: "\(host) 연결 확인 실패(\(outcome)) — 폰과 맥이 같은 네트워크인지 확인하세요."))
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
            let name = (isPairing ? String(localized: "페어링 대기중") : String(localized: "무선 디버깅")) + " (\(address))"
            services.append(MdnsService(name: name, address: address, isPairing: isPairing))
        }
        return services
    }

    // MARK: 데스크톱 디스플레이 앱 실행

    /// 데스크톱 가상 디스플레이에 앱을 freeform 창으로 연다(이미 열려 있으면 앞으로 가져온다).
    /// newInstance: 같은 앱의 새 창(NEW_TASK|MULTIPLE_TASK), restart: 기존 것을 끄고 새로(-S).
    static func startApp(serial: String, displayId: Int, app: AndroidApp,
                         newInstance: Bool = false, restart: Bool = false) async throws {
        var component = app.activity.map { "\(app.package)/\($0)" }
        if component == nil {
            let resolved = try await shell(
                serial: serial,
                "cmd package resolve-activity --brief -c android.intent.category.LAUNCHER \(app.package) | tail -n 1"
            ).trimmingCharacters(in: .whitespacesAndNewlines)
            guard resolved.contains("/") else {
                throw ADBError.failure(String(localized: "\(app.displayLabel): 실행할 수 있는 화면이 없는 앱입니다."))
            }
            component = resolved
        }
        var command = "am start --display \(displayId) --windowingMode 5"
        if newInstance { command += " -f 0x18000000" }
        if restart { command += " -S" }
        command += " -n \(component!)"
        let out = try await shell(serial: serial, command)
        if out.contains("Error") || out.contains("Exception") {
            throw ADBError.failure(out)
        }
    }

    // MARK: 데스크톱 창 관리 (MacDroid 제목줄용)

    /// 데스크톱 디스플레이의 앱 창(freeform 루트 태스크) — 위에 있는 창이 먼저.
    struct DesktopWindow: Sendable, Equatable, Identifiable {
        let id: Int              // 루트 태스크 id
        let package: String
        let component: String    // pkg/cls (앞으로 가져오기용)
        let bounds: CGRect       // 디스플레이 px
    }

    /// 데스크톱 창 목록 + 디스플레이 크기(홈 태스크 bounds).
    /* 파서 정책: `cmd activity stack list`는 루트 태스크를 z순서(위가 먼저)로
       "RootTask id=N bounds=[l,t][r,b] displayId=D", configuration(mWindowingMode·mActivityType),
       "taskId=N: pkg/cls ... visible=true" 순으로 낸다(실측 One UI 8/Android 17, 80ms).
       변경 전: freeform만 창으로 봤다. 변경 후: 일반 앱(activityType=standard)이면 창 모드와 무관하게 창으로 본다 —
       앱 안에서 연 다른 앱(링크 등)이 전체 화면으로 떠도 데스크톱에 보이게(전체 화면 = 최대화된 창).
       영향 범위: MacDroid 데스크톱 창 목록. */
    static func desktopWindows(serial: String, displayId: Int) async throws -> (windows: [DesktopWindow], displaySize: CGSize?) {
        let out = try await shell(serial: serial, "cmd activity stack list")
        var windows: [DesktopWindow] = []
        var displaySize: CGSize?
        var current: (id: Int, bounds: CGRect, standard: Bool, home: Bool, onDisplay: Bool)?

        func rect(_ text: Substring) -> CGRect? {
            let nums = text.split(whereSeparator: { !$0.isNumber && $0 != "-" }).compactMap { Int($0) }
            guard nums.count >= 4 else { return nil }
            return CGRect(x: nums[0], y: nums[1], width: nums[2] - nums[0], height: nums[3] - nums[1])
        }
        for line in out.split(separator: "\n") {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("RootTask id=") {
                let id = Int(t.dropFirst("RootTask id=".count).prefix { $0.isNumber }) ?? -1
                let boundsText = t.range(of: #"bounds=\[[-\d,]+\]\[[-\d,]+\]"#, options: .regularExpression).map { t[$0] }
                current = (id, boundsText.flatMap(rect) ?? .zero, false, false, t.contains("displayId=\(displayId) "))
            } else if t.hasPrefix("configuration="), current != nil {
                current!.standard = t.contains("mActivityType=standard")
                current!.home = t.contains("mActivityType=home")
            } else if t.hasPrefix("taskId="), let task = current, task.onDisplay {
                current = nil  // 루트 태스크당 첫 태스크만
                if task.home {
                    displaySize = task.bounds.size
                    continue
                }
                guard task.standard, t.contains("visible=true"),
                      let colon = t.firstIndex(of: ":") else { continue }
                let component = t[t.index(after: colon)...].split(separator: " ").first.map(String.init) ?? ""
                guard let slash = component.firstIndex(of: "/") else { continue }
                windows.append(DesktopWindow(id: task.id, package: String(component[..<slash]),
                                             component: component, bounds: task.bounds))
            }
        }
        return (windows, displaySize)
    }

    /// 창 이동·크기 변경(디스플레이 px).
    static func moveWindow(serial: String, taskId: Int, to frame: CGRect) async {
        let r = frame.integral
        _ = try? await shell(serial: serial,
                             "cmd activity task resize \(taskId) \(Int(r.minX)) \(Int(r.minY)) \(Int(r.maxX)) \(Int(r.maxY))")
    }

    /// 지금 떠 있는 MacDroid 데스크톱의 가상 디스플레이 id(없으면 nil) — CLI가 데스크톱에 앱을 열거나 창을 다룰 때.
    /* 판별: MacDroid 데스크톱 서버(vd_system_decorations=false)가 돌고 있고, "scrcpy" 가상 디스플레이 중
       홈(런처) 태스크가 없는 것(시스템 장식 없는 디스플레이 — CLI app launch 창은 런처가 붙는다). 여럿이면 가장 최근(id 최대). */
    static func macdroidDesktopDisplayId(serial: String) async -> Int? {
        guard let running = try? await shell(serial: serial,
                                             "pgrep -f '[s]crcpy.Server 4.1 .*vd_system_decorations=false' || true"),
              !running.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let displays = try? await shell(serial: serial, "dumpsys display | grep -o 'DisplayInfo{\"scrcpy\", displayId [0-9]*'")
        else { return nil }
        let candidates = Set(displays.split(separator: "\n").compactMap { Int($0.split(separator: " ").last ?? "") })
        guard !candidates.isEmpty else { return nil }
        var withHome = Set<Int>()
        if let stacks = try? await shell(serial: serial, "cmd activity stack list") {
            var display: Int?
            for line in stacks.split(separator: "\n") {
                let t = line.trimmingCharacters(in: .whitespaces)
                if t.hasPrefix("RootTask id="), let r = t.range(of: "displayId=") {
                    display = Int(t[r.upperBound...].prefix { $0.isNumber })
                } else if t.hasPrefix("configuration="), t.contains("mActivityType=home"), let display {
                    withHome.insert(display)
                }
            }
        }
        return candidates.subtracting(withHome).max()
    }

    /// 디스플레이 크기(px) — `wm size -d`.
    static func displaySize(serial: String, displayId: Int) async -> CGSize? {
        guard let out = try? await shell(serial: serial, "wm size -d \(displayId)"),
              let r = out.range(of: #"\d+x\d+"#, options: .regularExpression) else { return nil }
        let parts = out[r].split(separator: "x").compactMap { Double($0) }
        return parts.count == 2 ? CGSize(width: parts[0], height: parts[1]) : nil
    }

    /// 다른 디스플레이(폰 본 화면 등)에 이미 있는 앱 태스크를 데스크톱 디스플레이로 옮긴다.
    /// am start는 기존 태스크가 있으면 '앞으로 가져오기'만 하고 원래 디스플레이에 남겨 두기 때문(실측).
    static func moveAppToDisplay(serial: String, package: String, displayId: Int) async {
        guard let out = try? await shell(serial: serial, "cmd activity stack list") else { return }
        var root: (id: Int, onTarget: Bool)?
        for line in out.split(separator: "\n") {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("RootTask id=") {
                let id = Int(t.dropFirst("RootTask id=".count).prefix { $0.isNumber }) ?? -1
                root = (id, t.contains("displayId=\(displayId) "))
            } else if t.hasPrefix("taskId="), let task = root {
                root = nil
                guard !task.onTarget, t.contains(": \(package)/") else { continue }
                _ = try? await shell(serial: serial, "cmd activity display move-stack \(task.id) \(displayId)")
                return
            }
        }
    }

    static func closeWindow(serial: String, taskId: Int) async {
        _ = try? await shell(serial: serial, "cmd activity stack remove \(taskId)")
    }

    /// 최소화: 창을 데스크톱 디스플레이 오른쪽 아래 화면 밖으로 치운다(MacDroid는 최소화된 창을 그리지 않는다).
    /* 변경 전 정책: 기기 본 화면(디스플레이 0)으로 옮겨 숨겼다 — 폰 화면에 그 앱이 튀어나왔다(사용자 보고).
       변경 후 정책: 같은 데스크톱 디스플레이에 두고 오른쪽 아래 화면 밖(독 아래 구석, 안드로이드가 48px만 남김)으로
         옮긴다 — 폰 화면은 건드리지 않는다. 복원은 원래 위치로 resize. 예전 방식으로 폰에 가 있던 창도 복원되게
         복원 전에 데스크톱 디스플레이로 옮긴다(이미 있으면 영향 없음).
       영향 범위: 데스크톱 창 최소화/복원, 홈 버튼(모두 최소화). */
    static func minimizeWindow(serial: String, taskId: Int, parkAt frame: CGRect) async {
        await moveWindow(serial: serial, taskId: taskId, to: frame)
    }

    static func restoreWindow(serial: String, taskId: Int, displayId: Int, frame: CGRect) async {
        _ = try? await shell(serial: serial, "cmd activity display move-stack \(taskId) \(displayId)")
        await moveWindow(serial: serial, taskId: taskId, to: frame)
    }

    /// 창을 맨 앞으로(같은 액티비티를 그 디스플레이에 다시 start하면 기존 태스크가 앞으로 온다).
    static func focusWindow(serial: String, displayId: Int, component: String) async {
        _ = try? await shell(serial: serial, "am start --display \(displayId) -n \(component)")
    }

    // MARK: 데스크톱 상태표시줄 (소리·밝기·알림)

    /// 미디어 볼륨(현재, 최대) — "volume is 7 in range [0..15]".
    static func mediaVolume(serial: String) async -> (value: Int, max: Int)? {
        guard let out = try? await shell(serial: serial, "cmd media_session volume --stream 3 --get"),
              let range = out.range(of: #"volume is (\d+) in range \[(\d+)\.\.(\d+)\]"#, options: .regularExpression)
        else { return nil }
        let nums = out[range].split(whereSeparator: { !$0.isNumber }).compactMap { Int($0) }
        guard nums.count >= 3 else { return nil }
        return (nums[0], nums[2])
    }

    static func setMediaVolume(serial: String, _ value: Int) async {
        _ = try? await shell(serial: serial, "cmd media_session volume --stream 3 --set \(value)")
    }

    /// 화면 밝기(0~255)와 자동 밝기 여부.
    static func brightness(serial: String) async -> (value: Int, auto: Bool)? {
        guard let out = try? await shell(serial: serial,
                                         "settings get system screen_brightness; settings get system screen_brightness_mode")
        else { return nil }
        let lines = out.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
        guard lines.count >= 2, let value = Int(lines[0]) else { return nil }
        return (value, lines[1] == "1")
    }

    /// 밝기 설정 — 직접 값을 정하면 자동 밝기는 끈다(켜 두면 시스템이 곧 되돌린다).
    static func setBrightness(serial: String, _ value: Int) async {
        _ = try? await shell(serial: serial,
                             "settings put system screen_brightness_mode 0; settings put system screen_brightness \(max(1, min(value, 255)))")
    }

    static func setAutoBrightness(serial: String, _ on: Bool) async {
        _ = try? await shell(serial: serial, "settings put system screen_brightness_mode \(on ? 1 : 0)")
    }

    struct PhoneNotification: Sendable, Identifiable, Equatable {
        let id: String        // 알림 key
        let package: String
        let title: String
        let text: String
        let posted: Date?
    }

    /// 폰 알림 목록(최근 것이 먼저) — `dumpsys notification --noredact`의 Notification List 구역.
    /* 파서 정책: "NotificationRecord(… pkg=P … key=K: Notification(… flags=F …))" 줄로 레코드를 나누고, 그 안의
       when=, android.title=, android.text=/bigText= 값을 읽는다(값 형식 "String (내용)"/"null", 실측 One UI 8).
       묶음 요약(GROUP_SUMMARY)·상시 알림(ONGOING_EVENT)·제목/내용 없는 알림은 뺀다. 구역은 들여쓰기 2칸 머리줄에서 끝난다. */
    static func notifications(serial: String) async -> [PhoneNotification] {
        guard let out = try? await shell(serial: serial, "dumpsys notification --noredact") else { return [] }
        var result: [PhoneNotification] = []
        var inList = false
        var current: (key: String, pkg: String, skip: Bool, title: String?, text: String?, when: Date?)?

        func value(_ line: Substring, after prefix: String) -> String? {
            let raw = line.dropFirst(prefix.count)
            guard !raw.hasPrefix("null"), let open = raw.firstIndex(of: "("), let close = raw.lastIndex(of: ")"),
                  open < close else { return nil }
            let text = raw[raw.index(after: open)..<close].trimmingCharacters(in: .whitespaces)
            return text.isEmpty ? nil : text
        }
        func flush() {
            guard let c = current, !c.skip, c.title != nil || c.text != nil else { return }
            result.append(PhoneNotification(id: c.key, package: c.pkg, title: c.title ?? "", text: c.text ?? "",
                                            posted: c.when))
        }

        for rawLine in out.split(separator: "\n", omittingEmptySubsequences: false) {
            if rawLine.hasPrefix("  Notification List:") { inList = true; continue }
            guard inList else { continue }
            if rawLine.hasPrefix("  "), !rawLine.hasPrefix("   ") { break }   // 다음 구역
            let line = rawLine.drop { $0 == " " }
            if line.hasPrefix("NotificationRecord(") {
                flush()
                let text = String(line)
                func field(_ name: String, until end: Character) -> String {
                    guard let r = text.range(of: name) else { return "" }
                    return String(text[r.upperBound...].prefix { $0 != end })
                }
                let key = text.range(of: "key=").map { r in
                    String(text[r.upperBound...].components(separatedBy: ": Notification(").first ?? "")
                } ?? UUID().uuidString
                let flags = field("flags=", until: " ")
                current = (key, field("pkg=", until: " "),
                           flags.contains("GROUP_SUMMARY") || flags.contains("ONGOING_EVENT"), nil, nil, nil)
            } else if current != nil {
                if line.hasPrefix("android.title="), current?.title == nil {
                    current?.title = value(line, after: "android.title=")
                } else if line.hasPrefix("android.bigText=") {
                    if let big = value(line, after: "android.bigText=") { current?.text = big }
                } else if line.hasPrefix("android.text="), current?.text == nil {
                    current?.text = value(line, after: "android.text=")
                } else if line.hasPrefix("when="), current?.when == nil,
                          let ms = Double(line.dropFirst(5).prefix { $0.isNumber }), ms > 0 {
                    current?.when = Date(timeIntervalSince1970: ms / 1000)
                }
            }
        }
        flush()
        return result.sorted { ($0.posted ?? .distantPast) > ($1.posted ?? .distantPast) }
    }

    /// 알림 닫기.
    /* 정책: 셸(uid 2000)은 다른 앱의 알림을 취소(cancel)할 권한이 없다. 대신 `cmd notification snooze`는 허용되어
       100년 동안 다시 알리기로 미뤄 폰 알림창에서도 사라지게 한다(실측: 목록에서 즉시 빠짐). 사실상 닫기. */
    static func dismissNotification(serial: String, key: String) async {
        _ = try? await shell(serial: serial, "cmd notification snooze --for 3153600000000 \(shellQuoted(key))")
    }

    /// 블루투스 켜짐 여부.
    static func bluetoothOn(serial: String) async -> Bool? {
        guard let out = try? await shell(serial: serial, "settings get global bluetooth_on") else { return nil }
        return out.trimmingCharacters(in: .whitespacesAndNewlines) == "1"
    }

    /// 데스크톱 디스플레이에 시스템 화면(설정 액션)을 창으로 연다.
    static func openSystemPage(serial: String, displayId: Int, action: String) async {
        _ = try? await shell(serial: serial, "am start --display \(displayId) --windowingMode 5 -a \(action)")
    }

    /// 기기가 잠들었거나(Dozing/Asleep) 화면보호기(Dreaming)면 깨운다 — 잠금은 풀지 않는다.
    /* 정책: 잠금(키가드) 상태여도 기기가 깨어 있으면 데스크톱 가상 디스플레이는 정상 동작한다(실측: PIN 잠금,
       deviceLocked=1에서 앱 실행·표시 OK). 잠들면 가상 디스플레이도 검게 꺼지므로 데스크톱 세션 동안 깨워 둔다. */
    @discardableResult
    static func wakeIfAsleep(serial: String) async -> Bool {
        guard let out = try? await shell(serial: serial, "dumpsys power | grep -m1 mWakefulness="),
              !out.contains("Awake") else { return false }
        _ = try? await shell(serial: serial, "input keyevent KEYCODE_WAKEUP")
        return true
    }

    /// 예전 버전 MacDroid가 남긴 데스크톱 wakelock 정리(셸이 잡은 화면 wakelock = MacDroid 것).
    /* 정책: 지금은 폰 전원을 건드리지 않는다(DesktopSession '폰 상태' 정책). 다만 이전 버전이 데스크톱 디스플레이에
       잡아 둔 화면 wakelock이 남아 있으면 폰이 잠들지 못하므로 데스크톱을 열 때 놓아 준다. */
    static func releaseStaleDesktopWakelocks(serial: String) async {
        guard let list = try? await shell(serial: serial, "cmd power set-wakelock list") else { return }
        for line in list.split(separator: "\n") where line.contains("held=true") {
            let t = line.trimmingCharacters(in: .whitespaces)
            guard t.hasPrefix("Display "),
                  let id = Int(t.dropFirst("Display ".count).prefix { $0.isNumber }),
                  let typeRange = t.range(of: #"wakelock type: [A-Z_]+"#, options: .regularExpression)
            else { continue }
            let type = t[typeRange].dropFirst("wakelock type: ".count)
            _ = try? await shell(serial: serial, "cmd power set-wakelock release -d \(id) \(type)")
        }
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
            throw ADBError.failure(String(localized: "디스플레이 \(displayId) 캡처 실패 (screencap -d)"))
        }
        let data = try await ProcessRunner.runData(
            Binaries.adb, arguments: ["-s", serial, "exec-out", "screencap", "-p"], environment: env
        )
        guard data.isPNG else { throw ADBError.failure(String(localized: "screencap 실패 — 기기가 잠겨 있거나 화면이 꺼져 있을 수 있음")) }
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
