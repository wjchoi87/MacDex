import SwiftUI
import AppKit

/// 앱 창 내용 — 데스크톱 영상에서 그 창 영역만 잘라 그리고, 마우스·키보드를 기기로 보낸다.
/* 정책: 프레임은 IOSurface를 레이어 contents로 붙이고 contentsRect로 창 영역만 보여 준다(복사 없음, 창 여러 개가
   같은 프레임을 공유). 입력 좌표는 창 영역(px) 기준으로 가상 디스플레이 좌표로 바꿔 보낸다 — 기기도 같은 z순서라
   그 지점의 맨 위 창(= 클릭한 창)이 받는다.
   키보드: Esc는 뒤로가기(KEYCODE_BACK, 변경 전엔 KEYCODE_ESCAPE). 특수 키(엔터·지우기·방향키 등)와 Ctrl/Option 조합은 키코드로, 글자는 텍스트로 보낸다. ASCII 밖(한글 등)은
   서버의 텍스트 주입이 못 하므로 클립보드 붙여넣기로 넣는다. ⌘C/⌘X/⌘A/⌘Z는 Ctrl 조합으로, ⌘V는 맥 클립보드를 붙여 넣는다. */
final class DesktopVideoView: NSView, @preconcurrency NSTextInputClient {
    weak var session: DesktopSession?
    var windowID = 0
    /// 이 창의 기기 화면 영역(px).
    var crop: CGRect = .zero {
        didSet { if crop != oldValue { updateContentsRect() } }
    }

    private var pixelSize: CGSize = .zero
    private var buttons: UInt32 = 0
    private var keysDown: Set<UInt16> = []
    private var marked: String?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer = CALayer()
        layer?.backgroundColor = NSColor.black.cgColor
        layer?.contentsGravity = .resize
        layer?.masksToBounds = true
        layer?.minificationFilter = .linear
        layer?.magnificationFilter = .linear
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    @MainActor
    func show(_ surface: IOSurface, pixelSize: CGSize) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer?.contents = surface
        if self.pixelSize != pixelSize {
            self.pixelSize = pixelSize
            updateContentsRect()
        }
        CATransaction.commit()
    }

    private func updateContentsRect() {
        guard pixelSize.width > 0, pixelSize.height > 0, crop.width > 0 else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        // contentsRect는 단위 좌표 — 플립 뷰의 레이어라 원점이 이미지 위쪽(실측)
        layer?.contentsRect = CGRect(x: crop.minX / pixelSize.width,
                                     y: crop.minY / pixelSize.height,
                                     width: crop.width / pixelSize.width,
                                     height: crop.height / pixelSize.height)
        CATransaction.commit()
    }

    // MARK: 마우스

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .activeInKeyWindow, .inVisibleRect],
                                       owner: self))
    }

    private func devicePoint(_ event: NSEvent) -> CGPoint {
        let p = convert(event.locationInWindow, from: nil)
        guard bounds.width > 0, bounds.height > 0 else { return .zero }
        return CGPoint(x: crop.minX + p.x * crop.width / bounds.width,
                       y: crop.minY + p.y * crop.height / bounds.height)
    }

    private func press(_ event: NSEvent, button: UInt32) {
        session?.nudgeAwake()
        window?.makeFirstResponder(self)
        session?.raiseLocally(windowID)
        buttons |= button
        session?.input?.touch(.down, at: devicePoint(event), actionButton: button, buttons: buttons)
    }

    private func release(_ event: NSEvent, button: UInt32) {
        buttons &= ~button
        session?.input?.touch(.up, at: devicePoint(event), actionButton: button, buttons: buttons)
    }

    private func drag(_ event: NSEvent) {
        session?.input?.touch(.move, at: devicePoint(event), actionButton: 0, buttons: buttons)
    }

    override func mouseDown(with event: NSEvent) { press(event, button: DesktopStream.buttonPrimary) }
    override func mouseUp(with event: NSEvent) { release(event, button: DesktopStream.buttonPrimary) }
    override func mouseDragged(with event: NSEvent) { drag(event) }
    override func rightMouseDown(with event: NSEvent) { press(event, button: DesktopStream.buttonSecondary) }
    override func rightMouseUp(with event: NSEvent) { release(event, button: DesktopStream.buttonSecondary) }
    override func rightMouseDragged(with event: NSEvent) { drag(event) }
    /* 변경 전 정책: 가운데 버튼 외의 마우스 버튼(뒤로·앞으로 사이드 버튼)도 전부 가운데 클릭으로 보냈다.
       변경 후 정책: 버튼 3(뒤로) = 이 창의 뒤로가기(KEYCODE_BACK), 버튼 4(앞으로) = KEYCODE_FORWARD.
         가운데 버튼(2)과 그 밖의 버튼은 기존대로 가운데 클릭.
       변경 이유: 맥 마우스의 사이드 버튼으로 앱 뒤로가기를 쓰고 싶다는 요청.
       영향 범위: 데스크톱 앱 창 안에서 누른 마우스 사이드 버튼. */
    override func otherMouseDown(with event: NSEvent) {
        switch event.buttonNumber {
        case 3: session?.back(windowID: windowID)
        case 4: session?.input?.pressKey(125)   // KEYCODE_FORWARD
        default: press(event, button: DesktopStream.buttonTertiary)
        }
    }

    override func otherMouseUp(with event: NSEvent) {
        guard event.buttonNumber != 3, event.buttonNumber != 4 else { return }
        release(event, button: DesktopStream.buttonTertiary)
    }
    override func otherMouseDragged(with event: NSEvent) { drag(event) }

    override func mouseMoved(with event: NSEvent) {
        guard buttons == 0 else { return }
        session?.input?.touch(.hoverMove, at: devicePoint(event), actionButton: 0, buttons: 0)
    }

    override func scrollWheel(with event: NSEvent) {
        // 트랙패드(정밀 스크롤)는 pt 단위라 크게 나온다 — 휠 한 칸 수준으로 줄인다
        let factor: CGFloat = event.hasPreciseScrollingDeltas ? 0.08 : 1
        let dx = event.scrollingDeltaX * factor
        let dy = event.scrollingDeltaY * factor
        guard dx != 0 || dy != 0 else { return }
        session?.input?.scroll(at: devicePoint(event), dx: dx, dy: dy)
    }

    // MARK: 키보드

    /// macOS 키코드 → Android 키코드(글자가 아닌 키).
    private static let specialKeys: [UInt16: UInt32] = [
        36: 66, 76: 66,        // Return, Enter → ENTER
        48: 61,                // Tab
        51: 67,                // Delete → DEL(백스페이스)
        117: 112,              // Forward Delete
        53: 4,                 // Esc → BACK(뒤로가기 — 요청: Esc를 뒤로가기로)
        123: 21, 124: 22, 125: 20, 126: 19,   // ← → ↓ ↑
        115: 122, 119: 123,    // Home, End
        116: 92, 121: 93,      // Page Up/Down
    ]

    /// 글자 → Android 키코드(Ctrl/Option 조합용).
    private static func charKeycode(_ event: NSEvent) -> UInt32? {
        guard let scalar = event.charactersIgnoringModifiers?.lowercased().unicodeScalars.first else { return nil }
        let v = scalar.value
        if (0x61...0x7a).contains(v) { return 29 + (v - 0x61) }   // a-z → KEYCODE_A..Z
        if (0x30...0x39).contains(v) { return 7 + (v - 0x30) }    // 0-9
        let table: [Character: UInt32] = [
            " ": 62, ",": 55, ".": 56, "/": 76, "-": 69, "=": 70, "[": 71, "]": 72,
            "\\": 73, ";": 74, "'": 75, "`": 68,
        ]
        return table[Character(scalar)]
    }

    private static func metaState(_ flags: NSEvent.ModifierFlags) -> UInt32 {
        var meta: UInt32 = 0
        if flags.contains(.shift) { meta |= 0x41 }      // SHIFT_ON | SHIFT_LEFT_ON
        if flags.contains(.control) { meta |= 0x3000 }  // CTRL_ON | CTRL_LEFT_ON
        if flags.contains(.option) { meta |= 0x12 }     // ALT_ON | ALT_LEFT_ON
        return meta
    }

    override func keyDown(with event: NSEvent) {
        session?.nudgeAwake()
        guard let stream = session?.input else { return }
        let meta = Self.metaState(event.modifierFlags)
        if let code = Self.specialKeys[event.keyCode] {
            keysDown.insert(event.keyCode)
            stream.key(.down, keycode: code, metaState: meta)
            return
        }
        if event.modifierFlags.contains(.control) || event.modifierFlags.contains(.option),
           let code = Self.charKeycode(event) {
            keysDown.insert(event.keyCode)
            stream.key(.down, keycode: code, metaState: meta)
            return
        }
        interpretKeyEvents([event])
    }

    override func keyUp(with event: NSEvent) {
        guard keysDown.remove(event.keyCode) != nil, let stream = session?.input else { return }
        let meta = Self.metaState(event.modifierFlags)
        if let code = Self.specialKeys[event.keyCode] ?? Self.charKeycode(event) {
            stream.key(.up, keycode: code, metaState: meta)
        }
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard window?.firstResponder === self, event.type == .keyDown,
              event.modifierFlags.contains(.command),
              let key = event.charactersIgnoringModifiers?.lowercased() else { return false }
        switch key {
        case "v": paste(nil)
        case "c": copy(nil)
        case "x": cut(nil)
        case "a": selectAll(nil)
        case "z":
            sendCtrl(54, shift: event.modifierFlags.contains(.shift))   // KEYCODE_Z
        default:
            return false
        }
        return true
    }

    private func sendCtrl(_ keycode: UInt32, shift: Bool = false) {
        session?.input?.pressKey(keycode, metaState: 0x3000 | (shift ? 0x41 : 0))
    }

    @objc func paste(_ sender: Any?) {
        guard let text = NSPasteboard.general.string(forType: .string) else { return }
        session?.input?.setClipboard(text, paste: true)
    }

    @objc func copy(_ sender: Any?) { sendCtrl(31) }       // KEYCODE_C
    @objc func cut(_ sender: Any?) { sendCtrl(52) }        // KEYCODE_X
    override func selectAll(_ sender: Any?) { sendCtrl(29) }  // KEYCODE_A

    private func send(text: String) {
        guard !text.isEmpty, let stream = session?.input else { return }
        if text.unicodeScalars.allSatisfy({ $0.isASCII }) {
            stream.text(text)
        } else {
            stream.setClipboard(text, paste: true)
        }
    }

    // MARK: NSTextInputClient (한글 등 입력기 조합 → 확정된 글자만 보낸다)

    func insertText(_ string: Any, replacementRange: NSRange) {
        marked = nil
        let text = (string as? String) ?? (string as? NSAttributedString)?.string ?? ""
        send(text: text)
    }

    override func doCommand(by selector: Selector) {}

    func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        let text = (string as? String) ?? (string as? NSAttributedString)?.string ?? ""
        marked = text.isEmpty ? nil : text
    }

    func unmarkText() {
        if let marked { send(text: marked) }
        marked = nil
    }

    func selectedRange() -> NSRange { NSRange(location: 0, length: 0) }
    func markedRange() -> NSRange {
        marked.map { NSRange(location: 0, length: ($0 as NSString).length) } ?? NSRange(location: NSNotFound, length: 0)
    }
    func hasMarkedText() -> Bool { marked != nil }
    func attributedSubstring(forProposedRange range: NSRange, actualRange: NSRangePointer?) -> NSAttributedString? { nil }
    func validAttributesForMarkedText() -> [NSAttributedString.Key] { [] }
    func characterIndex(for point: NSPoint) -> Int { 0 }

    func firstRect(forCharacterRange range: NSRange, actualRange: NSRangePointer?) -> NSRect {
        // 입력기 후보창은 창 왼쪽 아래 근처에 띄운다(기기 커서 위치는 알 수 없다)
        guard let window else { return .zero }
        let rect = convert(NSRect(x: 12, y: bounds.height - 24, width: 1, height: 20), to: nil)
        return window.convertToScreen(rect)
    }
}

/// SwiftUI 래퍼.
struct DesktopVideo: NSViewRepresentable {
    let session: DesktopSession
    let windowID: Int
    let crop: CGRect

    func makeNSView(context: Context) -> DesktopVideoView {
        let view = DesktopVideoView(frame: .zero)
        view.session = session
        view.windowID = windowID
        view.crop = crop
        session.frames.register(view)
        return view
    }

    func updateNSView(_ view: DesktopVideoView, context: Context) {
        view.windowID = windowID
        view.crop = crop
    }
}
