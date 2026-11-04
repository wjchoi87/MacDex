import Foundation
import Darwin

/// scrcpy 세션 정의.
/// 정책: 세션 = 하나의 scrcpy 프로세스. 미러(실화면)와 DeX 앱 창(가상 디스플레이)은 같은 러너로 실행.
///   오디오는 기기 전체 재생을 캡처하므로, 같은 기기에서 여러 창을 띄우면 소리가 중복된다.
///   → 같은 기기의 첫 세션만 오디오를 켠다(첫 창이 닫히면 다음 창이 이어받지 않는 단순 규칙).
struct ScrcpySession: Identifiable, @unchecked Sendable {
    enum Mode: String, Sendable {
        case mirror
        case app
        case dex   // DeX 데스크톱 전체(작업표시줄+런처)를 가상 디스플레이에 띄우기
    }

    let id: String                 // serial|mode|package — 조회·중복판단용 안정 식별자
    let key: String                // UUID — 종료 이벤트 매칭용 1회성 식별자
    let deviceSerial: String
    let mode: Mode
    let title: String
    let startedAt = Date()

    /// 입양된 고아 세션이면 pid가 설정된다(우리가 spawn하지 않은 scrcpy — 앱 재시작 전 생존분).
    /// 이 세션은 process 핸들이 없어 kill(pid)로 종료하고, onExit 이벤트도 없어 목록 정리는 호출부가 한다.
    let externalPID: Int32?

    init(id: String, deviceSerial: String, mode: Mode, title: String, externalPID: Int32? = nil) {
        self.id = id
        self.key = UUID().uuidString
        self.deviceSerial = deviceSerial
        self.mode = mode
        self.title = title
        self.externalPID = externalPID
    }

    /* 정책: 같은 기기 미러를 재실행하면 같은 id의 새 세션이 등록되는데, 구 프로세스의
       onExit가 늦게 도착해 신세션을 지워버리는 레이스가 있다. 종료 이벤트는 1회성 key로
       매칭하고 id는 조회용으로만 쓴다. */
    fileprivate(set) var process: StreamingProcess?
    private let processLock = NSLock()

    mutating func attach(_ p: StreamingProcess) {
        processLock.lock()
        defer { processLock.unlock() }
        process = p
    }

    func terminate() {
        if let pid = externalPID {
            kill(pid, SIGTERM)
            return
        }
        processLock.lock()
        defer { processLock.unlock() }
        process?.terminate()
    }

    /// 프로세스가 아직 살아 있는지(고아: kill(pid,0), 소유: Process.isRunning).
    var isProcessAlive: Bool {
        if let pid = externalPID { return kill(pid, 0) == 0 }
        processLock.lock()
        defer { processLock.unlock() }
        return process?.isRunning ?? false
    }
}

/// scrcpy 인자 빌더 + 실행.
enum Scrcpy {

    static func makeID(serial: String, mode: ScrcpySession.Mode, package: String?) -> String {
        "\(serial)|\(mode.rawValue)|\(package ?? "-")"
    }

    /// 공통 인자: 연결·품질·편의 옵션.
    private static func commonArgs(device: Device, settings: MirrorSettings, audioAllowed: Bool) -> [String] {
        var args: [String] = ["-s", device.serial]

        // 비디오 품질
        args += ["--video-codec", settings.video.codec]
        args += ["--video-bit-rate", "\(settings.video.bitRateMbps)M"]
        if settings.video.maxSize > 0 {
            args += ["--max-size", "\(settings.video.maxSize)"]
        }
        if settings.video.maxFPS > 0 {
            args += ["--max-fps", "\(settings.video.maxFPS)"]
        }

        // 오디오
        if !settings.audioEnabled || !audioAllowed {
            args += ["--no-audio"]
        }

        // 편의 옵션
        if settings.stayAwake { args += ["--stay-awake"] }
        if settings.showTouches { args += ["--show-touches"] }

        // 고급 입력: uhid 물리 키보드/마우스 → 호버·게임 키·IME 경험 개선
        if settings.advancedInput {
            args += ["--keyboard=uhid", "--mouse=uhid"]
        }
        return args
    }

    /// 실화면 미러 창.
    static func mirrorArguments(device: Device, settings: MirrorSettings, audioAllowed: Bool) -> [String] {
        var args = commonArgs(device: device, settings: settings, audioAllowed: audioAllowed)
        args += ["--window-title", "MacDroid · \(device.displayModel)"]
        if settings.turnScreenOff { args += ["--turn-screen-off"] }
        return args
    }

    /// DeX 앱 창: 앱 전용 가상 디스플레이에서 실행(폰 화면과 독립).
    /// forceNewInstance: scrcpy '+' 프리픽스로 새 인스턴스 강제(이미 실행 중인 앱의 이중 창).
    /// windowOrigin: 데스크톱 계단식 배치용 초기 창 위치(맥에서 앱 여는 느낌).
    static func appArguments(device: Device, app: AndroidApp, settings: MirrorSettings, audioAllowed: Bool,
                             forceNewInstance: Bool = false,
                             windowOrigin: (x: Int, y: Int)? = nil) -> [String] {
        var args = commonArgs(device: device, settings: settings, audioAllowed: audioAllowed)
        let vd = settings.virtualDisplay
        args += ["--new-display=\(vd.width)x\(vd.height)/\(vd.density)"]
        args += ["--start-app=\(forceNewInstance ? "+" : "")\(app.package)"]
        args += ["--window-title", "MacDroid · \(app.displayLabel)"]
        if let origin = windowOrigin {
            args += ["--window-x", "\(origin.x)", "--window-y", "\(origin.y)"]
        }
        return args
    }

    /// scrcpy 서버 로그에서 새 가상 디스플레이 id 추출: "[server] INFO: New display: 1600x1000/160 (id=33)".
    static func parseNewDisplayID(_ line: String) -> Int? {
        guard line.contains("New display"),
              let range = line.range(of: #"\(id=(\d+)\)"#, options: .regularExpression) else { return nil }
        return Int(line[range].filter(\.isNumber))
    }

    /// 번들된 scrcpy-server 버전(예: "5.0.1") — 서버를 직접 띄울 때 첫 인자로 넘기는 값. 못 읽으면 nil.
    /* 변경 전 정책: DesktopStream이 서버 버전을 "4.1"로 하드코딩해 넘겼다.
       변경 후 정책: 번들 scrcpy 클라이언트의 `--version`에서 읽어 넘긴다(앱 실행당 1회, 캐시).
       변경 이유: 서버는 첫 인자가 자기 버전과 다르면 IllegalArgumentException으로 바로 죽는다. brew scrcpy가
         5.0.1로 오르자 fetch-vendor가 새 server를 번들했고 데스크톱 연결이 전부 실패했다(실측 2026-11-04).
         client와 server는 fetch-vendor가 같은 brew 설치에서 복사하므로(미러링도 이 짝이 맞아야 동작) 버전이 같다.
       영향 범위: MacDroid 데스크톱 서버 실행(DesktopStream). 미러링·앱 창은 scrcpy 클라이언트가 직접 맞추므로 무관.
       주의: DesktopStream 프로토콜은 4.1 소스 기준 — 4.1→5.0.1 server 소스 차이는 audio/camera뿐임을 확인(2026-11-04).
         메이저 업그레이드 때는 DesktopStream 헤더 주석의 프로토콜과 다시 대조할 것. */
    static let serverVersion: String? = {
        let process = Process()
        process.executableURL = Binaries.scrcpy
        process.arguments = ["--version"]
        process.environment = Binaries.processEnvironment
        let out = Pipe()
        process.standardOutput = out
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        // 첫 줄: "scrcpy 5.0.1 <https://github.com/Genymobile/scrcpy>"
        guard let first = String(data: data, encoding: .utf8)?.split(separator: "\n").first else { return nil }
        let parts = first.split(separator: " ")
        guard parts.count >= 2, parts[0] == "scrcpy", parts[1].first?.isNumber == true else { return nil }
        return String(parts[1])
    }()

    /// 세션 실행. 종료 이벤트는 SessionEvents로 방출된다(AppState가 정리).
    /// - Returns: 실행된 프로세스 핸들(세션에 attach해서 종료 가능하게).
    static func launch(arguments: [String], sessionID: String) throws -> StreamingProcess {
        let process = StreamingProcess()
        try process.start(
            executable: Binaries.scrcpy,
            arguments: arguments,
            environment: Binaries.processEnvironment,
            onExit: { _ in
                SessionEvents.shared.emitTerminated(sessionID: sessionID)
            }
        )
        return process
    }
}

/// scrcpy 프로세스 종료 이벤트 브릿(비동기 콜백 → MainActor AppState 전달).
final class SessionEvents: @unchecked Sendable {
    static let shared = SessionEvents()
    private let lock = NSLock()
    private var handlers: [(String) -> Void] = []

    func addHandler(_ handler: @escaping (String) -> Void) {
        lock.lock()
        defer { lock.unlock() }
        handlers.append(handler)
    }

    func emitTerminated(sessionID: String) {
        lock.lock()
        let current = handlers
        lock.unlock()
        for h in current { h(sessionID) }
    }
}
