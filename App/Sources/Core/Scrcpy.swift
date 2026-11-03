import Foundation

/// scrcpy 세션 정의.
/// 정책: 세션 = 하나의 scrcpy 프로세스. 미러(실화면)와 DeX 앱 창(가상 디스플레이)은 같은 러너로 실행.
///   오디오는 기기 전체 재생을 캡처하므로, 같은 기기에서 여러 창을 띄우면 소리가 중복된다.
///   → 같은 기기의 첫 세션만 오디오를 켠다(첫 창이 닫히면 다음 창이 이어받지 않는 단순 규칙).
struct ScrcpySession: Identifiable, @unchecked Sendable {
    enum Mode: String, Sendable {
        case mirror
        case app
    }

    let id: String                 // serial|mode|package — 조회·중복판단용 안정 식별자
    let key: String                // UUID — 종료 이벤트 매칭용 1회성 식별자
    let deviceSerial: String
    let mode: Mode
    let title: String
    let startedAt = Date()

    init(id: String, deviceSerial: String, mode: Mode, title: String) {
        self.id = id
        self.key = UUID().uuidString
        self.deviceSerial = deviceSerial
        self.mode = mode
        self.title = title
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
        processLock.lock()
        defer { processLock.unlock() }
        process?.terminate()
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
    static func appArguments(device: Device, app: AndroidApp, settings: MirrorSettings, audioAllowed: Bool) -> [String] {
        var args = commonArgs(device: device, settings: settings, audioAllowed: audioAllowed)
        let vd = settings.virtualDisplay
        args += ["--new-display=\(vd.width)x\(vd.height)/\(vd.density)"]
        args += ["--start-app=\(app.package)"]
        args += ["--window-title", "MacDroid · \(app.displayLabel)"]
        return args
    }

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
