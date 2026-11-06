import Foundation
import AppKit
import CoreMedia
import VideoToolbox
import os

/// MacDroid 데스크톱 스트림 — scrcpy-server(4.1)에 직접 붙는 자체 클라이언트.
/* 정책: scrcpy 클라이언트 창(SDL)을 쓰지 않는다. 가상 디스플레이 1개(삼성 런처·작업표시줄 없음 —
   vd_system_decorations=false)를 서버로 띄우고, 영상은 VideoToolbox로 직접 디코드해 MacDroid가 앱 창마다
   필요한 영역만 잘라 그린다(DesktopSession/DesktopView). 입력은 같은 서버의 control 소켓으로 보낸다.
   - 영상 1개(인코더 1개)로 창 여러 개 → 앱 실행은 am start만(0.1초), 창마다 scrcpy를 띄우지 않는다
   - 프로토콜(scrcpy 4.1 소스 기준): tunnel_forward → 첫 소켓(영상)에서 dummy 1바이트 + 기기 이름 64바이트,
     코덱 id 4바이트, 세션 헤더 12바이트(크기), 이후 [pts|flags 8][len 4][payload]. 세션 패킷(MSB=1)은 크기 변경.
   영향 범위: DeX 데스크톱 창에서만 쓴다. 미러링/CLI는 기존 scrcpy 그대로. */
final class DesktopStream: @unchecked Sendable {

    /// 스트림 제어 경로 진단 로그(Console.app — subsystem=MacDroid).
    static let log = Logger(subsystem: "kr.macdroid.MacDroid", category: "desktop-stream")

    struct Config: Sendable {
        let serial: String
        let width: Int
        let height: Int
        let density: Int
        let bitRateMbps: Int
        let maxFPS: Int
    }

    /// 서버가 만든 가상 디스플레이 id(앱 실행 대상).
    var onDisplayID: (@Sendable (Int) -> Void)?
    /// 디코드된 프레임(디코더 스레드에서 호출).
    var onFrame: (@Sendable (CVPixelBuffer) -> Void)?
    /// 영상 크기(px) — 시작·디스플레이 크기 변경 시.
    var onVideoSize: (@Sendable (CGSize) -> Void)?
    /// 기기 클립보드 변경(기기 → 맥 동기화).
    var onClipboard: (@Sendable (String) -> Void)?
    /// 종료(오류 메시지 또는 nil).
    var onEnd: (@Sendable (String?) -> Void)?

    private let config: Config
    private let scid = String(format: "%08x", UInt32.random(in: 1...0x7fff_ffff))
    private let lock = NSLock()
    private var server: StreamingProcess?
    private var videoSocket: Int32 = -1
    private var controlSocket: Int32 = -1
    private var stopped = false
    private var forwardPort: Int?
    private let controlQueue = DispatchQueue(label: "macdroid.desktop.control")
    private let decoder = H264Decoder()

    /// 현재 영상 크기(px) — 입력 좌표는 이 크기 기준이어야 서버가 받는다.
    private(set) var videoSize: CGSize {
        get { lock.withLock { _videoSize } }
        set { lock.withLock { _videoSize = newValue } }
    }
    private var _videoSize = CGSize.zero

    init(config: Config) {
        self.config = config
    }

    // MARK: 시작·종료

    func start() {
        Thread.detachNewThread { [self] in
            do {
                try run()
            } catch {
                finish(error.localizedDescription)
            }
        }
    }

    func stop() {
        let (server, video, control, port): (StreamingProcess?, Int32, Int32, Int?) = lock.withLock {
            stopped = true
            defer { self.server = nil; videoSocket = -1; controlSocket = -1; forwardPort = nil }
            return (self.server, videoSocket, controlSocket, forwardPort)
        }
        if video >= 0 { shutdown(video, SHUT_RDWR); close(video) }
        if control >= 0 { shutdown(control, SHUT_RDWR); close(control) }
        server?.terminate()
        if let port { removeForward(port) }
    }

    private var isStopped: Bool { lock.withLock { stopped } }

    private func finish(_ message: String?) {
        let wasStopped = isStopped
        stop()
        if !wasStopped { onEnd?(message) }
    }

    private func run() throws {
        let adb = Binaries.adb.path
        // 0) 예전 실행이 남긴 MacDroid 데스크톱 서버 정리(맥 쪽이 비정상 종료되거나 adb가 끊기면 폰에 남아
        //    가상 디스플레이·인코더를 계속 돌린다 — 배터리 낭비, 실측). 패턴의 [s]는 이 셸 명령 자신을 빼기 위함.
        try? runADB(["-s", config.serial, "shell",
                     "pkill -f '[s]crcpy.Server 4.1 .*vd_system_decorations=false' ; true"])
        // 1) 서버 jar 푸시(같은 파일이면 adb가 건너뛴다)
        try runADB(["-s", config.serial, "push", Binaries.scrcpyServer.path, "/data/local/tmp/scrcpy-server.jar"])
        // 2) 포워드: 로컬 임의 포트 → 기기 localabstract:scrcpy_<scid>
        let portText = try runADB(["-s", config.serial, "forward", "tcp:0", "localabstract:scrcpy_\(scid)"])
        guard let port = Int(portText.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            throw StreamError(String(localized: "adb forward 실패: \(portText)"))
        }
        lock.withLock { forwardPort = port }
        if isStopped { return }

        // 3) 서버 실행
        var params = [
            "scid=\(scid)", "log_level=info", "audio=false", "tunnel_forward=true",
            "video_codec=h264", "video_bit_rate=\(config.bitRateMbps * 1_000_000)",
            "new_display=\(config.width)x\(config.height)/\(config.density)",
            "flex_display=true", "vd_system_decorations=false",
            // display_ime_policy=hide 제거(실측 원인 후보): 이 정책이 붙은 디스플레이에서는 IME가
            // 조합 모드를 개시하지 않아 물리 키보드(uhid) 한글이 조합되지 않았다. IME 창이 데스크톱에
            // 뜨는 부작용이 있지만 한글 입력이 우선 — 동작 확인 후 정책 재조정.
        ]
        if config.maxFPS > 0 { params.append("max_fps=\(config.maxFPS)") }
        let command = "CLASSPATH=/data/local/tmp/scrcpy-server.jar app_process / com.genymobile.scrcpy.Server 4.1 "
            + params.joined(separator: " ")
        let process = StreamingProcess()
        try process.start(
            executable: URL(fileURLWithPath: adb),
            arguments: ["-s", config.serial, "shell", command],
            environment: Binaries.processEnvironment,
            onLine: { [weak self] line in
                // 서버 로그는 INFO 라인뿐 — 원인 진단(예: "Device clipboard set")에 필수라 통째로 흘린다
                Self.log.info("server: \(line, privacy: .public)")
                if let id = Scrcpy.parseNewDisplayID(line) { self?.onDisplayID?(id) }
            },
            onExit: { [weak self, weak process] _ in
                let tail = process?.stderrTail.split(separator: "\n").suffix(2).joined(separator: " ") ?? ""
                self?.finish(tail.isEmpty ? String(localized: "데스크톱 서버가 종료되었습니다") : tail)
            }
        )
        lock.withLock { server = process }

        // 4) 영상 소켓: 서버가 listen할 때까지 재시도(dummy 바이트로 확인), 이어서 control 소켓
        var video: Int32 = -1
        for _ in 0..<100 {
            if isStopped { return }
            let socket = try connectLocal(port: port)
            var byte: UInt8 = 0
            if recv(socket, &byte, 1, MSG_WAITALL) == 1 {
                video = socket
                break
            }
            close(socket)
            Thread.sleep(forTimeInterval: 0.1)
        }
        guard video >= 0 else { throw StreamError(String(localized: "데스크톱 서버에 연결하지 못했습니다")) }
        let control = try connectLocal(port: port)
        var one: Int32 = 1
        setsockopt(control, IPPROTO_TCP, TCP_NODELAY, &one, socklen_t(MemoryLayout<Int32>.size))
        lock.withLock {
            videoSocket = video
            controlSocket = control
        }
        removeForward(port)
        lock.withLock { forwardPort = nil }

        Thread.detachNewThread { [weak self] in self?.readDeviceMessages(control) }
        // uhid 물리 키보드 등록 — 한글 조합을 폰 IME가 직접 하게(아래 sendUhidKeyboardCreate 정책 참고)
        sendUhidKeyboardCreate()

        // 5) 기기 이름(64) → 코덱 id(4) → 세션 헤더(12)
        _ = try readExactly(video, 64)
        let codec = try readExactly(video, 4)
        guard codec.be32(0) == 0x6832_3634 else { throw StreamError(String(localized: "지원하지 않는 코덱")) }  // "h264"
        var header = try readExactly(video, 12)
        guard header[0] & 0x80 != 0 else { throw StreamError(String(localized: "잘못된 스트림 헤더")) }
        updateSize(header)

        // 6) 패킷 루프
        decoder.onFrame = { [weak self] buffer in self?.onFrame?(buffer) }
        while !isStopped {
            header = try readExactly(video, 12)
            if header[0] & 0x80 != 0 {
                updateSize(header)
                continue
            }
            let flags = header.be64(0)
            let length = Int(header.be32(8))
            guard length > 0 else { continue }
            let payload = try readExactly(video, length)
            let isConfig = flags & (1 << 62) != 0
            decoder.decode(payload, isConfig: isConfig)
        }
    }

    private func updateSize(_ header: [UInt8]) {
        let size = CGSize(width: Int(header.be32(4)), height: Int(header.be32(8)))
        videoSize = size
        onVideoSize?(size)
    }

    // MARK: 기기 메시지(클립보드)

    private func readDeviceMessages(_ socket: Int32) {
        while !isStopped {
            guard let type = try? readExactly(socket, 1) else { return }
            switch type[0] {
            case 0:  // CLIPBOARD: len(4) + utf8
                guard let len = try? readExactly(socket, 4),
                      let body = try? readExactly(socket, Int(len.be32(0))) else { return }
                // SET_CLIPBOARD 직후 이 echo가 오면 기기 클립보드 설정이 실제로 성공한 것이다(진단 신호)
                Self.log.info("device CLIPBOARD echo bytes=\(body.count, privacy: .public)")
                if let text = String(bytes: body, encoding: .utf8) { onClipboard?(text) }
            case 1:  // ACK_CLIPBOARD: sequence(8)
                guard (try? readExactly(socket, 8)) != nil else { return }
            case 2:  // UHID_OUTPUT: id(2) + size(2) + data
                guard let head = try? readExactly(socket, 4),
                      (try? readExactly(socket, Int(UInt16(head[2]) << 8 | UInt16(head[3])))) != nil else { return }
            default:
                return
            }
        }
    }

    // MARK: 제어 메시지(scrcpy control_msg.c 직렬화와 동일)

    enum MotionAction: UInt8 { case down = 0, up = 1, move = 2, hoverMove = 7 }
    enum KeyAction: UInt8 { case down = 0, up = 1 }

    static let pointerMouse = UInt64.max   // SC_POINTER_ID_MOUSE (-1)
    static let buttonPrimary: UInt32 = 1
    static let buttonSecondary: UInt32 = 2
    static let buttonTertiary: UInt32 = 4

    func touch(_ action: MotionAction, at point: CGPoint, actionButton: UInt32, buttons: UInt32) {
        let size = videoSize
        guard size.width > 0 else { return }
        var msg: [UInt8] = [2, action.rawValue]
        msg.appendBE(Self.pointerMouse)
        msg.appendPosition(point, size)
        let pressure: UInt16 = action == .up || action == .hoverMove ? 0 : 0xffff
        msg.appendBE(pressure)
        msg.appendBE(actionButton)
        msg.appendBE(buttons)
        send(msg)
    }

    /// 스크롤: 값 범위 [-16, 16](scrcpy와 동일).
    func scroll(at point: CGPoint, dx: CGFloat, dy: CGFloat) {
        let size = videoSize
        guard size.width > 0 else { return }
        func fixed(_ value: CGFloat) -> UInt16 {
            let norm = max(-1, min(1, value / 16))
            return UInt16(bitPattern: Int16(max(-32768, min(32767, Int(norm * 32768)))))
        }
        var msg: [UInt8] = [3]
        msg.appendPosition(point, size)
        msg.appendBE(fixed(dx))
        msg.appendBE(fixed(dy))
        msg.appendBE(UInt32(0))
        send(msg)
    }

    func key(_ action: KeyAction, keycode: UInt32, metaState: UInt32 = 0) {
        var msg: [UInt8] = [0, action.rawValue]
        msg.appendBE(keycode)
        msg.appendBE(UInt32(0))
        msg.appendBE(metaState)
        send(msg)
    }

    func pressKey(_ keycode: UInt32, metaState: UInt32 = 0) {
        key(.down, keycode: keycode, metaState: metaState)
        key(.up, keycode: keycode, metaState: metaState)
    }

    /// ASCII 텍스트 입력(서버가 KeyCharacterMap으로 키 이벤트로 바꾼다 — 한글은 불가, setClipboard(paste:) 사용).
    func text(_ text: String) {
        let bytes = Array(text.utf8.prefix(300))
        Self.log.info("control INJECT_TEXT bytes=\(bytes.count, privacy: .public)")
        var msg: [UInt8] = [1]
        msg.appendBE(UInt32(bytes.count))
        msg += bytes
        send(msg)
    }

    /// 기기 클립보드 설정(+붙여넣기) — 맥 → 기기, 한글 등 비ASCII 입력에도 쓴다.
    /* 변경 전 정책: paste=true로 SET_CLIPBOARD를 보내 서버가 KEYCODE_PASTE(279) 주입을 대신하게 했다.
       결함(실측): KEYCODE_PASTE는 하드웨어 '붙여넣기 전용키'라 이를 처리하는 앱이 거의 없다 — 크롬 주소창 등은
       무시해서 "SET_CLIPBOARD 전송됐는데 화면에 아무 글자도 안 찍히는" 한글 입력 불가가 발생했다.
       변경 후 정책: 클립보드만 설정(paste=false)하고 MacDroid가 직접 Ctrl+V(V + META_CTRL_ON) 키 이벤트를
       이어서 주입한다. 실측으로 "Device clipboard set"까지는 성공하는데 주입된 Ctrl+V가 무시되어, down과 up
       사이에 물리 키보드 수준의 시간차(50ms)를 둔다(동시 타임스탬프의 down/up 페어를 앱이 무시할 수 있다).
       영향 범위: 데스크톱 세션의 비ASCII(한글 등) 텍스트 입력과 ⌘V 붙여넣기. */
    func setClipboard(_ text: String, paste: Bool) {
        let bytes = Array(text.utf8)
        Self.log.info("control SET_CLIPBOARD bytes=\(bytes.count, privacy: .public) paste=\(paste, privacy: .public)")
        var msg: [UInt8] = [9]
        msg.appendBE(UInt64(0))   // sequence 0 = ack 불필요
        msg.append(0)             // paste=false — 붙여넣기 키는 클라이언트가 직접 주입
        msg.appendBE(UInt32(bytes.count))
        msg += bytes
        send(msg)
        guard paste else { return }
        key(.down, keycode: 50, metaState: 0x3000)   // KEYCODE_V + META_CTRL_ON|CTRL_LEFT_ON
        // 물리 키보드처럼 down을 누른 채 잠시 있다 뗀다 — serial 큐 순서 유지
        controlQueue.asyncAfter(deadline: .now() + .milliseconds(50)) { [weak self] in
            self?.key(.up, keycode: 50, metaState: 0x3000)
        }
    }

    /// 가상 디스플레이 크기 변경(flex_display).
    func resizeDisplay(width: Int, height: Int) {
        var msg: [UInt8] = [21]
        msg.appendBE(UInt16(width))
        msg.appendBE(UInt16(height))
        send(msg)
    }

    // MARK: uhid 물리 키보드

    /* 변경 전 정책(한글 입력): 글자를 macOS IME로 확정해 클립보드+붙여넣기(주입 Ctrl+V/KEYCODE_PASTE)로 넣었다.
       결함(실측): "Device clipboard set"까지는 성공하지만 주입된 붙여넣기 키를 크롬 등 대부분 앱이 무시해
       한글이 아예 입력되지 않았다. input text도 서버가 한글을 거부했다.
       변경 후 정책: UHID로 진짜 하드웨어 키보드를 등록하고 HID 키 리포트를 보낸다 — 폰 IME(삼성키보드 한국어)가
       물리 키보드처럼 직접 조합한다(한/영 전환은 폰 기준 Shift+Space). macOS IME는 거치지 않는다.
       프로토콜(scrcpy 서버 ControlMessageReader 기준): UHID_CREATE=14 [id 2][vendor 2][product 2][nameLen 1][name][descLen 2][desc],
       UHID_INPUT=15 [id 2][len 2][report]. descriptor와 8바이트 리포트(modifier+reserved+key×6)는 scrcpy
       app/src/hid/hid_keyboard.c 것과 동일하다. 서버에 별도 파라미터는 필요 없다(메시지 구동).
       영향 범위: DeX 데스크톱 창의 키보드 입력 전체. 마우스·클립보드 동기화·⌘ 단축키 주입은 기존 경로 유지. */
    private static let hidKeyboardDescriptor: [UInt8] = [
        0x05, 0x01,             // Usage Page (Generic Desktop)
        0x09, 0x06,             // Usage (Keyboard)
        0xA1, 0x01,             // Collection (Application)
        0x05, 0x07,             //   Usage Page (Key Codes)
        0x19, 0xE0, 0x29, 0xE7, //   Usage Min/Max (224..231: modifiers)
        0x15, 0x00, 0x25, 0x01, //   Logical Min/Max (0..1)
        0x75, 0x01, 0x95, 0x08, //   Report Size/Count (1bit × 8)
        0x81, 0x02,             //   Input: modifier byte
        0x75, 0x08, 0x95, 0x01, //   Report Size/Count (8bit × 1)
        0x81, 0x01,             //   Input: reserved byte (constant)
        0x05, 0x08,             //   Usage Page (LEDs)
        0x19, 0x01, 0x29, 0x05, //   Usage Min/Max (1..5)
        0x75, 0x01, 0x95, 0x05, //   1bit × 5
        0x91, 0x02,             //   Output: LED report
        0x75, 0x03, 0x95, 0x01, //   3bit × 1
        0x91, 0x01,             //   Output: LED padding (constant)
        0x05, 0x07,             //   Usage Page (Key Codes)
        0x19, 0x00, 0x29, 0x65, //   Usage Min/Max (0..101)
        0x15, 0x00, 0x25, 0x65, //   Logical Min/Max (0..101)
        0x75, 0x08, 0x95, 0x06, //   8bit × 6
        0x81, 0x00,             //   Input: key array
        0xC0,                   // End Collection
    ]

    /// uhid 키보드 디바이스 id(클라이언트 정의 식별자 — scrcpy 표준 1번).
    private static let hidKeyboardID: UInt16 = 1

    func sendUhidKeyboardCreate() {
        var msg: [UInt8] = [12]   // TYPE_UHID_CREATE (서버 ControlMessage.java 상수 — 13=INPUT, 14=DESTROY)
        msg.appendBE(Self.hidKeyboardID)
        msg.appendBE(UInt16(0))   // vendor id
        msg.appendBE(UInt16(0))   // product id
        msg.append(0)             // name 길이 0(빈 이름)
        msg.appendBE(UInt16(Self.hidKeyboardDescriptor.count))
        msg += Self.hidKeyboardDescriptor
        Self.log.info("control UHID_CREATE desc=\(Self.hidKeyboardDescriptor.count, privacy: .public)B")
        send(msg)
    }

    /// HID 키보드 리포트(8바이트: modifier, reserved, key×6) 전송.
    func uhidInput(_ report: [UInt8]) {
        var msg: [UInt8] = [13]   // TYPE_UHID_INPUT
        msg.appendBE(Self.hidKeyboardID)
        msg.appendBE(UInt16(report.count))
        msg += report
        send(msg)
    }

    private func send(_ msg: [UInt8]) {
        controlQueue.async { [weak self] in
            guard let self else { return }
            let socket = self.lock.withLock { self.controlSocket }
            guard socket >= 0 else { return }
            msg.withUnsafeBytes { raw in
                var offset = 0
                while offset < raw.count {
                    let n = Darwin.send(socket, raw.baseAddress! + offset, raw.count - offset, 0)
                    if n <= 0 { return }
                    offset += n
                }
            }
        }
    }

    // MARK: 소켓·adb 도우미

    private func connectLocal(port: Int) throws -> Int32 {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw StreamError(String(localized: "소켓 생성 실패")) }
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(UInt16(port).bigEndian)
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        let result = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard result == 0 else {
            close(fd)
            throw StreamError(String(localized: "로컬 포트 연결 실패"))
        }
        var noSigPipe: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))
        return fd
    }

    private func readExactly(_ socket: Int32, _ count: Int) throws -> [UInt8] {
        var buffer = [UInt8](repeating: 0, count: count)
        var offset = 0
        while offset < count {
            let n = buffer.withUnsafeMutableBytes { recv(socket, $0.baseAddress! + offset, count - offset, 0) }
            guard n > 0 else { throw StreamError(isStopped ? String(localized: "중지됨") : String(localized: "기기와 연결이 끊어졌습니다")) }
            offset += n
        }
        return buffer
    }

    @discardableResult
    private func runADB(_ arguments: [String]) throws -> String {
        let process = Process()
        process.executableURL = Binaries.adb
        process.arguments = arguments
        process.environment = Binaries.processEnvironment
        let out = Pipe()
        process.standardOutput = out
        process.standardError = out
        try process.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let text = String(data: data, encoding: .utf8) ?? ""
        guard process.terminationStatus == 0 else { throw StreamError(text.trimmingCharacters(in: .whitespacesAndNewlines)) }
        return text
    }

    private func removeForward(_ port: Int) {
        try? runADB(["-s", config.serial, "forward", "--remove", "tcp:\(port)"])
    }

    struct StreamError: LocalizedError {
        let message: String
        init(_ message: String) { self.message = message }
        var errorDescription: String? { message }
    }
}

// MARK: - H.264 디코더(VideoToolbox)

/// Annex-B H.264 → CVPixelBuffer(BGRA, IOSurface). 설정 패킷(SPS/PPS)이 바뀌면 세션을 다시 만든다.
final class H264Decoder: @unchecked Sendable {
    var onFrame: (@Sendable (CVPixelBuffer) -> Void)?

    private var format: CMVideoFormatDescription?
    private var session: VTDecompressionSession?
    private var parameterSets: [[UInt8]] = []

    deinit {
        if let session { VTDecompressionSessionInvalidate(session) }
    }

    func decode(_ data: [UInt8], isConfig: Bool) {
        let units = Self.nalUnits(data)
        let sets = units.filter { let t = $0.first.map { $0 & 0x1f } ?? 0; return t == 7 || t == 8 }
        if !sets.isEmpty, sets != parameterSets {
            parameterSets = sets
            makeSession()
        }
        if isConfig { return }
        let frames = units.filter { let t = $0.first.map { $0 & 0x1f } ?? 0; return t != 7 && t != 8 && t != 9 }
        guard !frames.isEmpty, let format, let session else { return }

        // AVCC: [길이 4바이트][NAL]
        var avcc = [UInt8]()
        avcc.reserveCapacity(data.count + frames.count * 4)
        for unit in frames {
            avcc.appendBE(UInt32(unit.count))
            avcc += unit
        }
        var block: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(allocator: kCFAllocatorDefault, memoryBlock: nil,
                                                 blockLength: avcc.count, blockAllocator: kCFAllocatorDefault,
                                                 customBlockSource: nil, offsetToData: 0, dataLength: avcc.count,
                                                 flags: 0, blockBufferOut: &block) == noErr,
              let block else { return }
        avcc.withUnsafeBytes { raw in
            _ = CMBlockBufferReplaceDataBytes(with: raw.baseAddress!, blockBuffer: block,
                                              offsetIntoDestination: 0, dataLength: avcc.count)
        }
        var sample: CMSampleBuffer?
        var sizes = [avcc.count]
        guard CMSampleBufferCreateReady(allocator: kCFAllocatorDefault, dataBuffer: block, formatDescription: format,
                                        sampleCount: 1, sampleTimingEntryCount: 0, sampleTimingArray: nil,
                                        sampleSizeEntryCount: 1, sampleSizeArray: &sizes,
                                        sampleBufferOut: &sample) == noErr,
              let sample else { return }
        let handler = onFrame
        VTDecompressionSessionDecodeFrame(session, sampleBuffer: sample, flags: [], infoFlagsOut: nil) { status, _, image, _, _ in
            guard status == noErr, let image else { return }
            handler?(image)
        }
    }

    private func makeSession() {
        if let session { VTDecompressionSessionInvalidate(session) }
        session = nil
        format = nil
        guard let sps = parameterSets.first(where: { ($0[0] & 0x1f) == 7 }),
              let pps = parameterSets.first(where: { ($0[0] & 0x1f) == 8 }) else { return }
        var description: CMFormatDescription?
        let status = sps.withUnsafeBufferPointer { spsPtr in
            pps.withUnsafeBufferPointer { ppsPtr in
                let pointers = [spsPtr.baseAddress!, ppsPtr.baseAddress!]
                let sizes = [sps.count, pps.count]
                return CMVideoFormatDescriptionCreateFromH264ParameterSets(
                    allocator: kCFAllocatorDefault, parameterSetCount: 2, parameterSetPointers: pointers,
                    parameterSetSizes: sizes, nalUnitHeaderLength: 4, formatDescriptionOut: &description)
            }
        }
        guard status == noErr, let description else { return }
        let attributes: [CFString: Any] = [
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
            kCVPixelBufferIOSurfacePropertiesKey: [String: Any](),
        ]
        var created: VTDecompressionSession?
        guard VTDecompressionSessionCreate(allocator: kCFAllocatorDefault, formatDescription: description,
                                           decoderSpecification: nil,
                                           imageBufferAttributes: attributes as CFDictionary,
                                           outputCallback: nil, decompressionSessionOut: &created) == noErr,
              let created else { return }
        VTSessionSetProperty(created, key: kVTDecompressionPropertyKey_RealTime, value: kCFBooleanTrue)
        format = description
        session = created
    }

    /// Annex-B 시작 코드(00 00 01 / 00 00 00 01)로 NAL 분리.
    static func nalUnits(_ data: [UInt8]) -> [[UInt8]] {
        var units: [[UInt8]] = []
        var start = -1
        var i = 0
        let n = data.count
        while i + 2 < n {
            if data[i] == 0, data[i + 1] == 0, data[i + 2] == 1 {
                if start >= 0 {
                    var end = i
                    if end > start, data[end - 1] == 0 { end -= 1 }
                    if end > start { units.append(Array(data[start..<end])) }
                }
                i += 3
                start = i
                continue
            }
            i += 1
        }
        if start >= 0, start < n { units.append(Array(data[start..<n])) }
        if start < 0, !data.isEmpty { units.append(data) }  // 시작 코드 없는 단일 NAL
        return units
    }
}

// MARK: - 바이트 도우미

private extension Array where Element == UInt8 {
    mutating func appendBE<T: FixedWidthInteger>(_ value: T) {
        Swift.withUnsafeBytes(of: value.bigEndian) { append(contentsOf: $0) }
    }

    mutating func appendPosition(_ point: CGPoint, _ size: CGSize) {
        appendBE(Int32(point.x.rounded()))
        appendBE(Int32(point.y.rounded()))
        appendBE(UInt16(size.width))
        appendBE(UInt16(size.height))
    }

    func be32(_ offset: Int) -> UInt32 {
        self[offset..<offset + 4].reduce(0) { $0 << 8 | UInt32($1) }
    }

    func be64(_ offset: Int) -> UInt64 {
        self[offset..<offset + 8].reduce(0) { $0 << 8 | UInt64($1) }
    }
}
