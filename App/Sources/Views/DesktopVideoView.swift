import SwiftUI
import AppKit
import os

/// 앱 창 내용 — 데스크톱 영상에서 그 창 영역만 잘라 그리고, 마우스·키보드를 기기로 보낸다.
/* 정책: 프레임은 IOSurface를 레이어 contents로 붙이고 contentsRect로 창 영역만 보여 준다(복사 없음, 창 여러 개가
   같은 프레임을 공유). 입력 좌표는 창 영역(px) 기준으로 가상 디스플레이 좌표로 바꿔 보낸다 — 기기도 같은 z순서라
   그 지점의 맨 위 창(= 클릭한 창)이 받는다.
   키보드: Esc는 뒤로가기(KEYCODE_BACK, 변경 전엔 KEYCODE_ESCAPE). 특수 키(엔터·지우기·방향키 등)와 Ctrl/Option 조합은 키코드로, 글자는 텍스트로 보낸다. ASCII 밖(한글 등)은
   서버의 텍스트 주입이 못 하므로 클립보드 붙여넣기로 넣는다. ⌘C/⌘X/⌘A/⌘Z는 Ctrl 조합으로, ⌘V는 맥 클립보드를 붙여 넣는다. */
final class DesktopVideoView: NSView, @preconcurrency NSTextInputClient {
    /// 입력 경로 진단 로그 — 한글 입력이 어느 단계에서 끊기는지 Console.app(subsystem=MacDroid)에서 확인용.
    /// 입력 내용 자체는 찍지 않는다(개인정보) — 길이·ASCII 여부·분기만.
    static let log = Logger(subsystem: "kr.macdroid.MacDroid", category: "desktop-input")

    weak var session: DesktopSession?
    var windowID = 0
    /// 이 창의 기기 화면 영역(px).
    var crop: CGRect = .zero {
        didSet { if crop != oldValue { updateContentsRect() } }
    }

    private var pixelSize: CGSize = .zero
    private var buttons: UInt32 = 0
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

    // MARK: 키보드 (uhid HID — 폰 IME가 조합)

    /* 변경 전 정책: 글자는 macOS IME로 확정(interpretKeyEvents→insertText)해 ASCII는 서버 텍스트 주입,
         한글은 클립보드+붙여넣기로 넣었다. 특수키/조합은 Android keycode 주입.
       결함(실측): 주입된 붙여넣기 키(Ctrl+V·KEYCODE_PASTE)를 앱들이 무시해 한글이 입력되지 않았다.
       변경 후 정책: 물리 키코드를 HID 리포트로 그대로 보낸다(uhid 키보드 — DesktopStream 정책 참고) —
         한글 조합은 폰 IME가 직접 한다(한/영 전환: Shift+Space). 규칙:
         · Esc는 기존대로 뒤로가기(Android BACK 주입), ⌘ 조합은 performKeyEquivalent(기존) 유지
         · Shift/Ctrl/Option은 리포트 modifier 비트로 반영. Command는 HID GUI가 Android Meta로 오해될 수 있어 제외
         · macOS IME 경로(interpretKeyEvents)는 쓰지 않는다 — 조합을 폰이 맡는다.
       영향 범위: 데스크톱 앱 창 키보드 입력 전체. */
    /// macOS 가상 키코드 → HID usage(USB HID Usage Tables — a=0x04…).
    private static let hidUsage: [UInt16: UInt8] = [
        0x00: 0x04, 0x01: 0x16, 0x02: 0x07, 0x03: 0x09, 0x04: 0x0B, 0x05: 0x0A, // a s d f h g
        0x06: 0x1D, 0x07: 0x1B, 0x08: 0x06, 0x09: 0x19, 0x0B: 0x05,             // z x c v b
        0x0C: 0x14, 0x0D: 0x1A, 0x0E: 0x08, 0x0F: 0x15, 0x10: 0x1C, 0x11: 0x17, // q w e r y t
        0x12: 0x1E, 0x13: 0x1F, 0x14: 0x20, 0x15: 0x21, 0x16: 0x23, 0x17: 0x22, // 1 2 3 4 6 5
        0x18: 0x2E, 0x19: 0x25, 0x1A: 0x24, 0x1B: 0x2D, 0x1C: 0x26, 0x1D: 0x27, // = 9 7 - 8 0
        0x1E: 0x30, 0x1F: 0x12, 0x20: 0x18, 0x21: 0x2F, 0x22: 0x0C, 0x23: 0x13, // ] o u [ i p
        0x24: 0x28, 0x25: 0x0F, 0x26: 0x0D, 0x27: 0x34, 0x28: 0x0E, 0x29: 0x33, // return l j ' k ;
        0x2A: 0x31, 0x2B: 0x36, 0x2C: 0x38, 0x2D: 0x11, 0x2E: 0x10, 0x2F: 0x37, // \ , / n m .
        0x30: 0x2B, 0x31: 0x2C, 0x32: 0x35, 0x33: 0x2A, 0x39: 0x39,             // tab space ` backspace caps
        0x3A: 0x3A, 0x3B: 0x3B, 0x3C: 0x3C, 0x3D: 0x3D,                          // F1 F2 F3 F4
        0x3E: 0x3E, 0x3F: 0x3F, 0x40: 0x40, 0x41: 0x41, 0x42: 0x42, 0x43: 0x43, // F5…F10
        0x47: 0x44, 0x48: 0x45,                                                  // F11 F12
        0x72: 0x49, 0x73: 0x4A, 0x74: 0x4B, 0x75: 0x4C, 0x77: 0x4D, 0x79: 0x4E, // help home pgup fwd-del end pgdn
        0x7B: 0x50, 0x7C: 0x4F, 0x7D: 0x51, 0x7E: 0x52,                          // ← → ↓ ↑
    ]

    /// 지금 눌려 있는 HID 키(usage) — 리포트 재계산용.
    private var hidKeys: Set<UInt8> = []
    /// 직전 Caps Lock 상태(flagsChanged에서 토글 감지용).
    private var capsLockOn = false

    /// Shift/Ctrl/Option → HID modifier 비트(Command 제외).
    private static func hidModifiers(_ flags: NSEvent.ModifierFlags) -> UInt8 {
        var bits: UInt8 = 0
        if flags.contains(.shift) { bits |= 0x02 }   // LShift
        if flags.contains(.control) { bits |= 0x01 } // LCtrl
        if flags.contains(.option) { bits |= 0x04 }  // LAlt
        return bits
    }

    private func sendHIDReport(_ modifiers: UInt8) {
        guard let stream = session?.input else { return }
        let keys = hidKeys.sorted()
        var report: [UInt8]
        if keys.count > 6 {
            report = [modifiers, 0, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01]  // phantom rollover
        } else {
            report = [modifiers, 0, 0, 0, 0, 0, 0, 0]
            for (i, key) in keys.enumerated() { report[2 + i] = key }
        }
        stream.uhidInput(report)
    }

    override func keyDown(with event: NSEvent) {
        session?.nudgeAwake()
        // 본체가 켜져 있으면 한글 IME가 데스크톱에 안 붙는다 — 안내 배너 조건 체크(DesktopSession 정책)
        session?.markKeyboardUsed()
        // Esc = 뒤로가기(기존 UX — Android BACK 주입)
        if event.keyCode == 53 { session?.back(); return }
        // ⌘ 조합은 performKeyEquivalent(기존 주입 경로)가 담당 — HID의 GUI(Modifier)는 Android Meta로 오해되니 제외
        guard !event.modifierFlags.contains(.command), !event.isARepeat,
              let usage = Self.hidUsage[event.keyCode] else {
            Self.log.debug("keyDown skipped keyCode=\(event.keyCode, privacy: .public)")
            return
        }
        hidKeys.insert(usage)
        sendHIDReport(Self.hidModifiers(event.modifierFlags))
    }

    override func keyUp(with event: NSEvent) {
        guard let usage = Self.hidUsage[event.keyCode] else { return }
        hidKeys.remove(usage)
        sendHIDReport(Self.hidModifiers(event.modifierFlags))
    }

    override func flagsChanged(with event: NSEvent) {
        // Caps Lock은 macOS가 modifier 플래그로만 알려준다 — 토글 시 HID 키 down/up으로 전달한다
        let caps = event.modifierFlags.contains(.capsLock)
        if caps && !capsLockOn, let stream = session?.input {
            var report = [UInt8](repeating: 0, count: 8)
            report[2] = 0x39   // HID Caps Lock
            stream.uhidInput(report)
            stream.uhidInput([0, 0, 0, 0, 0, 0, 0, 0])
        }
        capsLockOn = caps
        // modifier 눌림/해제 반영 — 키 목록은 그대로 두고 modifier 비트만 갱신해 재전송
        sendHIDReport(Self.hidModifiers(event.modifierFlags))
    }

    override func resignFirstResponder() -> Bool {
        // 포커스를 잃을 때 눌려 있는 키를 해제한다(해제 리포트를 안 보내면 폰에서 키가 눌린 채 남는다)
        if !hidKeys.isEmpty {
            hidKeys.removeAll()
            sendHIDReport(0)
        }
        return super.resignFirstResponder()
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
            sendHIDCombo(modifier: event.modifierFlags.contains(.shift) ? 0x03 : 0x01,
                         key: 0x1D)   // (Ctrl|Shift) + Z
        default:
            return false
        }
        return true
    }

    /* 변경 전 정책: ⌘C/X/A/Z는 Android keycode 주입(Ctrl 조합), ⌘V는 맥 클립보드를 기기 클립보드로
         복사 + 붙여넣기 키 주입(setClipboard+paste)로 처리했다.
       결함(실측): 주입된 Ctrl 조합/붙여넣기 키를 앱들이 무시해 동작하지 않았다(한글 입력과 같은 원인).
       변경 후 정책: 단축키 전부를 uhid HID 리포트(Ctrl+글자)로 보낸다 — 물리 키보드의 Ctrl 조합과
         동일해 앱들이 일관되게 처리한다. 이로써 setClipboard(클립보드 복사) 경로는 데스크톱에서 완전히 사라진다.
       영향 범위: 데스크톱 앱 창의 ⌘ 단축키(붙여넣기·복사·잘라내기·전체선택·실행취소). */
    private func sendHIDCombo(modifier: UInt8, key: UInt8) {
        guard let stream = session?.input else { return }
        stream.uhidInput([modifier, 0, key, 0, 0, 0, 0, 0])   // down
        stream.uhidInput([0, 0, 0, 0, 0, 0, 0, 0])             // up
    }

    @objc func paste(_ sender: Any?) {
        sendHIDCombo(modifier: 0x01, key: 0x19)   // Ctrl + V
    }

    @objc func copy(_ sender: Any?) {
        sendHIDCombo(modifier: 0x01, key: 0x06)   // Ctrl + C
    }

    @objc func cut(_ sender: Any?) {
        sendHIDCombo(modifier: 0x01, key: 0x1B)   // Ctrl + X
    }

    override func selectAll(_ sender: Any?) {
        sendHIDCombo(modifier: 0x01, key: 0x04)   // Ctrl + A
    }

    private func send(text: String) {
        guard !text.isEmpty, let stream = session?.input else { return }
        let isASCII = text.unicodeScalars.allSatisfy(\.isASCII)
        Self.log.info("send text len=\(text.count, privacy: .public) ascii=\(isASCII, privacy: .public) → \(isASCII ? "injectText" : "clipboard+paste", privacy: .public)")
        if isASCII {
            stream.text(text)
        } else {
            stream.setClipboard(text, paste: true)
        }
    }

    // MARK: NSTextInputClient (한글 등 입력기 조합 → 확정된 글자만 보낸다)

    func insertText(_ string: Any, replacementRange: NSRange) {
        marked = nil
        let text = (string as? String) ?? (string as? NSAttributedString)?.string ?? ""
        Self.log.info("insertText len=\(text.count, privacy: .public) ascii=\(text.unicodeScalars.allSatisfy(\.isASCII), privacy: .public)")
        send(text: text)
    }

    override func doCommand(by selector: Selector) {}

    func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        let text = (string as? String) ?? (string as? NSAttributedString)?.string ?? ""
        Self.log.debug("setMarkedText len=\(text.count, privacy: .public)")
        marked = text.isEmpty ? nil : text
    }

    func unmarkText() {
        Self.log.debug("unmarkText len=\(self.marked?.count ?? 0, privacy: .public)")
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
