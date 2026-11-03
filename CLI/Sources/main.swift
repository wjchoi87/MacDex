import Foundation
import Darwin

/// macdroid CLI — 에이전트/스크립트가 DeX와 폰을 다루는 자동화 인터페이스.
/// 설계 원칙: (1) 모든 조회 명령에 --json (2) 안정적 exit code 0/1/2
///   (3) app launch/mirror start는 세션 파일로 생존 관리(pid) (4) 의존성 제로.
///
/// 사용법: macdroid <command> [subcommand] [args...]
let exitCode = await CLI.main(Array(CommandLine.arguments.dropFirst()))
exit(exitCode)

enum CLI {

    static let version = "1.0.0"

    // MARK: 진입

    static func main(_ args: [String]) async -> Int32 {
        guard Binaries.adbAvailable else {
            err("adb를 찾을 수 없습니다 — MacDroid.app 설치 또는 MACDROID_BIN 설정")
            return 1
        }
        guard let command = args.first else {
            usage()
            return 2
        }
        let rest = Array(args.dropFirst())
        do {
            switch command {
            case "devices":  try await devices(rest)
            case "info":     try await info(rest)
            case "app":      try await app(rest)
            case "mirror":   try await mirror(rest)
            case "screenshot": try await screenshot(rest)
            case "tap":      try await tap(rest)
            case "text":     try await text(rest)
            case "key":      try await key(rest)
            case "push":     try await push(rest)
            case "pull":     try await pull(rest)
            case "connect":  try await connect(rest)
            case "pair":     try await pairCmd(rest)
            case "--help", "-h", "help":
                usage(); return 0
            case "--version", "-v":
                print("macdroid \(version)")
            default:
                err("알 수 없는 명령: \(command)")
                usage()
                return 2
            }
            return 0
        } catch let error as ADBError {
            err("실패: \(error.localizedDescription)")
            return 1
        } catch {
            err("실패: \(error.localizedDescription)")
            return 1
        }
    }

    // MARK: 명령: devices / info

    static func devices(_ args: [String]) async throws {
        let json = args.contains("--json")
        let list = try await ADB.listDevices()
        if json {
            struct Row: Codable { let serial: String; let state: String; let connection: String }
            let rows = list.map { Row(serial: $0.serial, state: $0.state.rawValue, connection: $0.isUSB ? "usb" : "wifi") }
            printJSON(rows)
        } else {
            guard !list.isEmpty else { print("연결된 기기 없음"); return }
            for d in list {
                print("\(d.serial)\t\(d.state.rawValue)\t\(d.isUSB ? "usb" : "wifi")")
            }
        }
    }

    static func info(_ args: [String]) async throws {
        let json = args.contains("--json")
        guard let serial = args.first(where: { !$0.hasPrefix("--") }) else { usageInfo(); exit(2) }
        guard let base = try await ADB.listDevices().first(where: { $0.serial == serial }) else {
            throw ADBError.failure("기기를 찾을 수 없음: \(serial) — `macdroid devices`로 확인")
        }
        let device = await ADB.fillDeviceDetails(base)
        if json {
            struct Battery: Codable { let level: Int?; let charging: Bool? }
            struct Row: Codable {
                let serial: String; let state: String; let connection: String
                let model: String?; let brand: String?; let manufacturer: String?
                let androidVersion: String?; let sdk: Int?
                let battery: Battery; let screenSize: String?
            }
            printJSON(Row(
                serial: device.serial, state: device.state.rawValue,
                connection: device.isUSB ? "usb" : "wifi",
                model: device.model, brand: device.brand, manufacturer: device.manufacturer,
                androidVersion: device.androidVersion, sdk: device.sdkInt,
                battery: Battery(level: device.batteryLevel, charging: device.isCharging),
                screenSize: device.screenSize
            ))
        } else {
            print("serial: \(device.serial) (\(device.state.rawValue), \(device.isUSB ? "USB" : "Wi-Fi"))")
            print("model: \(device.model ?? "-")  brand: \(device.brand ?? "-")")
            print("android: \(device.androidVersion ?? "-") (API \(device.sdkInt.map(String.init) ?? "-"))")
            print("battery: \(device.batteryLevel.map { "\($0)%" + (device.isCharging == true ? " (충전중)" : "") } ?? "-")")
            print("screen: \(device.screenSize ?? "-")")
        }
    }

    // MARK: 명령: app list / launch / stop

    static func app(_ args: [String]) async throws {
        guard let sub = args.first else { usageApp(); exit(2) }
        let rest = Array(args.dropFirst())
        switch sub {
        case "list":   try await appList(rest)
        case "launch": try await appLaunch(rest)
        case "stop":   try await appStop(rest)
        default: err("알 수 없는 app 하위명령: \(sub)"); usageApp(); exit(2)
        }
    }

    static func appList(_ args: [String]) async throws {
        let json = args.contains("--json")
        let includeSystem = args.contains("--system")
        let resolveLabels = args.contains("--labels")
        guard let serial = args.first(where: { !$0.hasPrefix("--") }) else { usageApp(); exit(2) }

        var apps = try await ADB.installedApps(serial: serial, includeSystem: includeSystem)
        if resolveLabels {
            // 라벨 해석은 APK pull이 필요해 느림(첫 회만 — 이후 캐시) — 진행률은 stderr
            for index in apps.indices {
                var updated = await AppCatalog.loadMetadata(serial: serial, app: apps[index])
                if updated.label == nil, let cached = apps[index].label { updated.label = cached }
                apps[index] = updated
                FileHandle.standardError.write("라벨 해석 중… \(index + 1)/\(apps.count)\r".data(using: .utf8)!)
            }
            FileHandle.standardError.write("\n".data(using: .utf8)!)
        }
        if json {
            struct Row: Codable { let package: String; let label: String? }
            printJSON(apps.map { Row(package: $0.package, label: $0.label) })
        } else {
            for app in apps {
                print("\(app.package)\t\(app.label ?? "")")
            }
        }
    }

    static func appLaunch(_ args: [String]) async throws {
        let json = args.contains("--json")
        let noAudio = args.contains("--no-audio")
        let newInstance = args.contains("--new-instance")
        let displaySpec = flagValue(args, "--display") ?? "\(MirrorSettings.default.virtualDisplay.width)x\(MirrorSettings.default.virtualDisplay.height)/\(MirrorSettings.default.virtualDisplay.density)"
        let positional = positionalArgs(args)
        guard positional.count >= 2 else { usageApp(); exit(2) }
        let serial = positional[0]
        let package = positional[1]

        var settings = MirrorSettings.default
        settings.audioEnabled = !noAudio
        // --display WxH/DPI 해석
        let parts = displaySpec.split(separator: "/")
        if let dims = parts.first?.split(separator: "x"), dims.count == 2,
           let w = Int(dims[0]), let h = Int(dims[1]) {
            settings.virtualDisplay.width = w
            settings.virtualDisplay.height = h
            if parts.count > 1, let dpi = Int(parts[1]) { settings.virtualDisplay.density = dpi }
        }
        let device = Device(serial: serial, state: .online)
        let placeholder = AndroidApp(package: package, apkPath: nil)
        let scrcpyArgs = Scrcpy.appArguments(
            device: device, app: placeholder, settings: settings,
            audioAllowed: settings.audioEnabled, forceNewInstance: newInstance
        )

        // 가상디스플레이 id 감지: 실행 전 디스플레이 집합 → 실행 후 새 id
        let displaysBefore = Set((try? await ADB.displayIds(serial: serial)) ?? [])
        let session = try await CLISessions.spawnScrcpy(kind: .app, serial: serial, package: package, arguments: scrcpyArgs)
        let displayId = await CLISessions.pollNewDisplayId(serial: serial, before: displaysBefore, timeout: 12)
        try CLISessions.update(session, displayId: displayId)

        if json {
            struct Row: Codable { let session: String; let pid: Int32; let displayId: Int?; let log: String }
            printJSON(Row(session: session.id, pid: session.pid, displayId: displayId, log: session.logPath))
        } else {
            print("실행됨: \(package)  session=\(session.id)  pid=\(session.pid)\(displayId.map { "  displayId=\($0)" } ?? "")")
            print("캡처: macdroid screenshot \(serial) -d \(displayId.map(String.init) ?? "?")")
        }
    }

    static func appStop(_ args: [String]) async throws {
        let all = args.contains("--all")
        let positional = args.filter { !$0.hasPrefix("--") }
        guard let serial = positional.first else { usageApp(); exit(2) }
        if all {
            let count = try await CLISessions.terminateAll(serial: serial)
            print("종료됨: \(count)개 세션")
        } else {
            guard positional.count >= 2 else { usageApp(); exit(2) }
            let count = try await CLISessions.terminate(serial: serial, package: positional[1])
            print(count > 0 ? "종료됨: \(positional[1])" : "실행 중인 세션 없음: \(positional[1])")
        }
    }

    // MARK: 명령: mirror start / stop

    static func mirror(_ args: [String]) async throws {
        guard let sub = args.first, let serial = args.dropFirst().first(where: { !$0.hasPrefix("--") }) else {
            usageMirror(); exit(2)
        }
        let json = args.contains("--json")
        switch sub {
        case "start":
            let settings = MirrorSettings.default
            let device = Device(serial: serial, state: .online)
            let scrcpyArgs = Scrcpy.mirrorArguments(device: device, settings: settings, audioAllowed: settings.audioEnabled)
            let session = try await CLISessions.spawnScrcpy(kind: .mirror, serial: serial, package: nil, arguments: scrcpyArgs)
            if json {
                struct Row: Codable { let session: String; let pid: Int32; let log: String }
                printJSON(Row(session: session.id, pid: session.pid, log: session.logPath))
            } else {
                print("미러 시작: \(serial)  session=\(session.id)  pid=\(session.pid)")
            }
        case "stop":
            let count = try await CLISessions.terminateAll(serial: serial, kind: .mirror)
            print("종료됨: \(count)개 미러")
        default:
            err("알 수 없는 mirror 하위명령: \(sub)"); usageMirror(); exit(2)
        }
    }

    // MARK: 명령: screenshot / tap / text / key

    static func screenshot(_ args: [String]) async throws {
        let displayId = flagValue(args, "-d").flatMap(Int.init)
        let positional = positionalArgs(args)
        guard let serial = positional.first else {
            usageScreenshot(); exit(2)
        }
        let output = positional.count >= 2 ? positional[1] : defaultScreenshotName(serial: serial, displayId: displayId)
        let data = try await ADB.screenshotData(serial: serial, displayId: displayId)
        try data.write(to: URL(fileURLWithPath: output))
        print("저장됨: \(output) (\(data.count) bytes)\(displayId.map { "  displayId=\($0)" } ?? "")")
    }

    static func tap(_ args: [String]) async throws {
        let displayId = flagValue(args, "-d").flatMap(Int.init)
        let values = positionalArgs(args)
        guard values.count >= 3, let x = Int(values[1]), let y = Int(values[2]) else {
            usageInput(); exit(2)
        }
        try await ADB.input(serial: values[0], displayId: displayId, ["tap", "\(x)", "\(y)"])
        print("tap (\(x), \(y))" + (displayId.map { " @display \($0)" } ?? ""))
    }

    static func text(_ args: [String]) async throws {
        let displayId = flagValue(args, "-d").flatMap(Int.init)
        let positional = positionalArgs(args)
        guard positional.count >= 2 else { usageInput(); exit(2) }
        let serial = positional[0]
        let body = positional.dropFirst().joined(separator: " ")
        if !body.allSatisfy({ $0.isASCII }) {
            FileHandle.standardError.write("경고: input text는 ASCII만 지원 — 한글은 기기 IME로 직접 입력하거나 ADBKeyboard 앱 필요\n".data(using: .utf8)!)
        }
        try await ADB.input(serial: serial, displayId: displayId, ["text", ADB.shellQuoted(body)])
        print("text 입력: \(body)")
    }

    static func key(_ args: [String]) async throws {
        let displayId = flagValue(args, "-d").flatMap(Int.init)
        let positional = positionalArgs(args)
        guard positional.count >= 2 else { usageInput(); exit(2) }
        let serial = positional[0]
        let name = positional[1].lowercased()
        let keycodes: [String: Int] = [
            "back": 4, "home": 3, "recents": 187, "app_switch": 187,
            "enter": 66, "esc": 111, "escape": 111, "del": 67, "backspace": 67,
            "power": 26, "volume_up": 24, "volume_down": 25, "volume_mute": 164,
            "tab": 61, "space": 62, "up": 19, "down": 20, "left": 21, "right": 22,
            "menu": 82, "center": 23, "dpad_center": 23,
            // 잠긴/꺼진 화면에선 input이 무시된다(실측) — 에이전트가 깨우도록 제공
            "wakeup": 224, "sleep": 223,
        ]
        guard let code = keycodes[name] ?? Int(name) else {
            throw ADBError.failure("알 수 없는 키: \(name) — 이름(\(keycodes.keys.sorted().joined(separator: ", "))) 또는 숫자 keycode")
        }
        try await ADB.input(serial: serial, displayId: displayId, ["keyevent", "\(code)"])
        print("key \(name)(=\(code))" + (displayId.map { " @display \($0)" } ?? ""))
    }

    // MARK: 명령: push / pull / connect / pair

    static func push(_ args: [String]) async throws {
        let positional = positionalArgs(args)
        guard positional.count >= 2 else { usageFiles(); exit(2) }
        let serial = positional[0]
        let file = URL(fileURLWithPath: positional[1]).resolvingSymlinksInPath()
        let destination = positional.count >= 3 ? positional[2] : "/sdcard/Download/"
        try await ADB.push(serial: serial, file: file, destination: destination)
        print("전송 완료: \(file.lastPathComponent) → \(destination)")
    }

    static func pull(_ args: [String]) async throws {
        let positional = positionalArgs(args)
        guard positional.count >= 2 else { usageFiles(); exit(2) }
        let serial = positional[0]
        let remote = positional[1]
        let local = positional.count >= 3
            ? URL(fileURLWithPath: positional[2])
            : URL(fileURLWithPath: (remote as NSString).lastPathComponent)
        try await ADB.pull(serial: serial, remote: remote, to: local)
        print("수신 완료: \(remote) → \(local.path)")
    }

    static func connect(_ args: [String]) async throws {
        guard let host = args.first(where: { !$0.hasPrefix("--") }) else { usageWireless(); exit(2) }
        let output = try await ADB.connect(host: host)
        print(output.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    static func pairCmd(_ args: [String]) async throws {
        let positional = args.filter { !$0.hasPrefix("--") }
        guard positional.count >= 2 else { usageWireless(); exit(2) }
        let output = try await ADB.pair(host: positional[0], code: positional[1])
        print(output.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    // MARK: 사용법/유틸

    /// 값 없는 플래그를 제거하고, 값을 갖는 플래그(-d N, --display V)는 플래그+값을
    /// 함께 제거한 뒤 순수 위치 인자만 돌려준다. ("tap serial -d 6 540 1200" → [serial, 540, 1200])
    static func positionalArgs(_ args: [String], valueFlags: [String] = ["-d", "--display"]) -> [String] {
        var out: [String] = []
        var skipNext = false
        for arg in args {
            if skipNext { skipNext = false; continue }
            if valueFlags.contains(arg) { skipNext = true; continue }
            if arg.hasPrefix("-") { continue }  // 불리언 플래그(--json 등)
            out.append(arg)
        }
        return out
    }

    static func flagValue(_ args: [String], _ flag: String) -> String? {
        guard let index = args.firstIndex(of: flag), index + 1 < args.count else { return nil }
        return args[index + 1]
    }

    static func defaultScreenshotName(serial: String, displayId: Int?) -> String {
        let stamp = ISO8601DateFormatter().string(from: Date())
            .replacingOccurrences(of: ":", with: "-")
        return "screenshot-\(serial)-d\(displayId.map(String.init) ?? "main")-\(stamp).png"
    }

    static func printJSON<T: Encodable>(_ value: T) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(value), let text = String(data: data, encoding: .utf8) {
            print(text)
        }
    }

    static func err(_ message: String) {
        FileHandle.standardError.write(("macdroid: " + message + "\n").data(using: .utf8)!)
    }

    static func usage() {
        print("""
        macdroid \(version) — 에이전트/스크립트용 Android DeX CLI

        사용법: macdroid <command> [args...]

        기기:
          devices                          기기 목록 [--json]
          info <serial>                    기기 상세 [--json]
        앱(DeX 창):
          app list <serial>                설치된 앱 [--json] [--system] [--labels(느림,첫회)]
          app launch <serial> <package>    가상디스플레이 창 실행 [--display WxH/DPI]
                                           [--new-instance] [--no-audio] [--json]
          app stop <serial> <package>      창 종료 (또는 app stop <serial> --all)
        미러:
          mirror start <serial>            화면 미러 시작 [--json]
          mirror stop <serial>             미러 종료
        화면/입력:
          screenshot <serial> [out.png]    캡처 [-d displayId]
          tap <serial> <x> <y>             탭 [-d displayId]
          text <serial> <text>             텍스트 주입(ASCII) [-d displayId]
          key <serial> <key>               back/home/enter/wakeup/power/volume_up... 또는 숫자 [-d displayId]
        파일/무선:
          push <serial> <local> [remote]   파일 전송(기본 /sdcard/Download/)
          pull <serial> <remote> [local]   파일 수신
          connect <host:port>              무선 연결
          pair <host:port> <code>          무선 페어링(6자리 코드)

        참고:
          - 기기 화면이 꺼져 있으면 input이 무시됩니다 → `macdroid key <serial> wakeup`
          - app launch가 돌려주는 displayId로 screenshot/tap/text/key에 -d 지정
          - exit code: 0 성공 · 1 런타임 실패 · 2 사용법 오류
        """)
    }

    static func usageInfo() { err("사용법: macdroid info <serial> [--json]") }
    static func usageApp() {
        err("사용법: macdroid app list <serial> [--json] [--system] [--labels]")
        err("        macdroid app launch <serial> <package> [--display WxH/DPI] [--new-instance] [--json]")
        err("        macdroid app stop <serial> <package> | macdroid app stop <serial> --all")
    }
    static func usageMirror() {
        err("사용법: macdroid mirror start <serial> [--json]")
        err("        macdroid mirror stop <serial>")
    }
    static func usageScreenshot() { err("사용법: macdroid screenshot <serial> [out.png] [-d displayId]") }
    static func usageInput() { err("사용법: macdroid tap <serial> <x> <y> [-d id] · text <serial> <text> [-d id] · key <serial> <key> [-d id]") }
    static func usageFiles() {
        err("사용법: macdroid push <serial> <local> [remote]")
        err("        macdroid pull <serial> <remote> [local]")
    }
    static func usageWireless() {
        err("사용법: macdroid connect <host:port>")
        err("        macdroid pair <host:port> <code>")
    }
}
