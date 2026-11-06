import SwiftUI
import AppKit
import CoreVideo

/// MacDroid 데스크톱 세션 — 스트림 1개, 가상 디스플레이 1개, 그 위의 앱 창들을 우리 데스크톱 창으로 관리한다.
/* 정책:
   - 좌표: 데스크톱 캔버스(상태표시줄과 작업표시줄 사이, pt)와 가상 디스플레이(px)는 같은 영역을 비율 r(px/pt)로
     1:1 대응한다. 앱 창 bounds(px)/r = 캔버스 위 창 위치(pt). 앱 창 위에 MacDroid 제목줄(30pt)을 붙인다.
   - 해상도: r = 화면 배율(Retina 2)에서 긴 변 3200px 이하로 낮춘다(인코더·대역폭 한도, 실측 3200px 60fps 동작).
     DPI = 160 × r — 1dp가 1pt로 보여 맥 앱과 같은 크기.
   - 창 목록: 0.35초마다 `cmd activity stack list`(80ms)로 위치·z순서를 맞춘다(드래그 중에는 멈춤).
   - 조작: 이동/크기 = 놓는 순간 task resize, 닫기 = stack remove, 최소화 = 기기 본 화면으로 옮겨 숨김,
     최대화 = 캔버스 전체(제목줄 자리 제외) ↔ 이전 크기.
   - 독·바탕화면 아이콘·배경화면은 기기별로 UserDefaults에 저장한다.
   영향 범위: 데스크톱 창이 열려 있는 동안. 창을 닫으면 스트림을 끊고 가상 디스플레이(그 위 앱 창)도 사라진다. */
@MainActor
@Observable
final class DesktopSession {

    enum Phase: Equatable {
        case idle
        case starting
        case running
        case failed(String)
    }

    struct Minimized: Identifiable, Equatable {
        let id: Int
        let package: String
        let frame: CGRect   // px
    }

    static let titleBarHeight: CGFloat = 30
    /// 아래쪽 떠 있는 독이 차지하는 높이(pt) — 최대화·분할·바탕화면 아이콘은 이 위까지만 쓴다.
    static let dockReserve: CGFloat = 84
    private static let maxVideoSide: CGFloat = 3200

    let serial: String
    let frames = FrameHub()

    private(set) var phase: Phase = .idle
    private(set) var displayId: Int?
    private(set) var windows: [ADB.DesktopWindow] = []     // 위에 있는 창이 먼저
    private(set) var minimized: [Minimized] = []
    private(set) var canvasSize: CGSize = .zero
    private(set) var videoSize: CGSize = .zero
    private(set) var launching: Set<String> = []
    /// 드래그/크기 조절 중인 창의 임시 영역(캔버스 pt, 앱 내용 영역).
    var dragFrames: [Int: CGRect] = [:]

    private(set) var apps: [AndroidApp] = []
    private(set) var appsLoaded = false
    private(set) var appsLoading = false
    private(set) var dockPackages: [String] = []
    /// 바탕화면 항목(앱 패키지 또는 "folder:<id>") — 순서대로 자동 배치된다.
    private(set) var desktopPackages: [String] = []
    /// 바탕화면 폴더(id → 이름·앱 목록).
    private(set) var folders: [String: DesktopFolder] = [:]
    /// 바탕화면 아이콘 위치(캔버스 pt, 왼쪽 위) — 끌어다 놓은 아이콘만. 없으면 빈 칸에 자동 배치.
    private(set) var iconPositions: [String: CGPoint] = [:]
    private(set) var wallpaperPath: String?
    /// 폰 알림(상태표시줄 알림 목록) — 데스크톱이 떠 있는 동안 30초마다, 목록을 열 때 즉시 갱신.
    private(set) var notifications: [ADB.PhoneNotification] = []
    private(set) var bluetoothOn: Bool?
    /// 창을 화면 가장자리로 끌 때 붙을 자리(캔버스 pt, 제목줄 포함) — 미리보기 표시용.
    var snapPreview: CGRect?

    private weak var appState: AppState?
    private var stream: DesktopStream?
    private var pollTask: Task<Void, Never>?
    private var lastAwakeCheck = Date.distantPast
    /// 폰이 잠들어(화면 꺼짐·화면보호기) 데스크톱이 멈춘 상태인지 — 5초마다 확인.
    private(set) var phoneAsleep = false
    private var phoneStateTask: Task<Void, Never>?
    private var notificationTask: Task<Void, Never>?
    private var resizeTask: Task<Void, Never>?
    private var pending: [(app: AndroidApp, newInstance: Bool, restart: Bool)] = []
    private var restoreFrames: [Int: CGRect] = [:]
    /// 기기에 반영 중인 최소화·닫기(그 사이 폴링이 옛 목록으로 되살리지 않게).
    private var hiding: Set<Int> = []
    private var labels: [String: String] = [:]
    private var icons: [String: NSImage] = [:]

    /// 독·바탕화면 저장 키 — 기기 고유 시리얼(무선 주소 ip:port는 재연결마다 바뀐다).
    private var storageID: String

    /* 변경 전 정책: 독·바탕화면 아이콘을 adb 시리얼(무선이면 ip:port) 키로 저장 — 재연결로 포트가 바뀌면 설정이 사라졌다.
       변경 후 정책: 기기 고유 시리얼(ro.serialno, 없으면 mDNS 이름 속 시리얼) 키로 저장. 새 키에 아무것도 없고
         예전 키 저장분이 한 벌뿐이면 그것을 가져온다(기기 1대 사용자의 기존 배치 보존).
         창을 여는 시점에 기기 상세(시리얼)가 아직 없으면 데스크톱 시작 때 폰에서 직접 읽어 키를 옮긴다
         (resolveStorageID — 실측: 무선 재연결 직후엔 ip:port 키로 저장되고 있었다).
       영향 범위: 데스크톱 독 고정·바탕화면 아이콘·아이콘 위치(UserDefaults desktop.*.<기기 시리얼>). */
    init(serial: String, appState: AppState) {
        self.serial = serial
        self.appState = appState
        storageID = Self.stableID(serial: serial, serialNo: appState.device(for: serial)?.serialNo)
        let defaults = UserDefaults.standard
        Self.migrateLegacy(to: storageID)
        dockPackages = defaults.stringArray(forKey: "desktop.dock.\(storageID)")
            ?? ["com.sec.android.app.myfiles", "com.sec.android.gallery3d", "com.android.chrome", "com.android.settings"]
        desktopPackages = defaults.stringArray(forKey: "desktop.icons.\(storageID)") ?? []
        folders = Self.loadFolders(storageID)
        if let saved = defaults.dictionary(forKey: "desktop.iconpos.\(storageID)") as? [String: [Double]] {
            iconPositions = saved.compactMapValues { $0.count == 2 ? CGPoint(x: $0[0], y: $0[1]) : nil }
        }
        wallpaperPath = defaults.string(forKey: "desktop.wallpaper")
    }

    private static func stableID(serial: String, serialNo: String?) -> String {
        if let serialNo, !serialNo.isEmpty { return serialNo }
        // adb-<시리얼>-<임의>._adb-tls-connect._tcp
        if serial.hasPrefix("adb-"), let end = serial.dropFirst(4).firstIndex(of: "-") {
            return String(serial[serial.index(serial.startIndex, offsetBy: 4)..<end])
        }
        return serial
    }

    private static func migrateLegacy(to id: String) {
        let defaults = UserDefaults.standard
        let all = defaults.dictionaryRepresentation().keys
        for kind in ["dock", "icons", "iconpos"] where defaults.object(forKey: "desktop.\(kind).\(id)") == nil {
            let legacy = all.filter { $0.hasPrefix("desktop.\(kind).") && $0 != "desktop.\(kind).\(id)" }
            if legacy.count == 1, let key = legacy.first, let value = defaults.object(forKey: key) {
                defaults.set(value, forKey: "desktop.\(kind).\(id)")
            }
        }
    }

    /// px/pt 비율(가상 디스플레이 ↔ 캔버스).
    var ratio: CGFloat {
        guard canvasSize.width > 0, videoSize.width > 0 else { return 1 }
        return videoSize.width / canvasSize.width
    }

    // MARK: 시작·종료

    /// 캔버스 크기를 알게 되면(데스크톱 창 첫 배치) 스트림을 시작하고, 이후 크기가 바뀌면 디스플레이를 맞춘다.
    func canvasChanged(_ size: CGSize, backingScale: CGFloat) {
        guard size.width > 200, size.height > 200 else { return }
        canvasSize = size
        switch phase {
        case .idle:
            start(backingScale: backingScale)
        case .running, .starting:
            scheduleDisplayResize(backingScale: backingScale)
        case .failed:
            break
        }
    }

    func retry() {
        stop()
        phase = .idle
        if canvasSize.width > 0 { start(backingScale: NSScreen.main?.backingScaleFactor ?? 2) }
    }

    private func videoPixels(for size: CGSize, backingScale: CGFloat) -> (Int, Int, Int) {
        let r = min(max(backingScale, 1), Self.maxVideoSide / max(size.width, size.height))
        let w = Int(size.width * r) / 8 * 8
        let h = Int(size.height * r) / 8 * 8
        return (w, h, Int((160 * r).rounded()))
    }

    /// 저장 키를 기기 고유 시리얼로 확정한다 — 새 키에 저장분이 있으면 그걸 읽고, 없으면 지금 상태를 옮겨 적는다.
    private func resolveStorageID() async {
        var serialNo = appState?.device(for: serial)?.serialNo
        if serialNo == nil {
            serialNo = (try? await ADB.shell(serial: serial, "getprop ro.serialno"))?
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard let id = serialNo, !id.isEmpty, id != storageID else { return }
        storageID = id
        let defaults = UserDefaults.standard
        if let dock = defaults.stringArray(forKey: "desktop.dock.\(id)") { dockPackages = dock }
        else { defaults.set(dockPackages, forKey: "desktop.dock.\(id)") }
        if let icons = defaults.stringArray(forKey: "desktop.icons.\(id)") {
            desktopPackages = icons
            folders = Self.loadFolders(id)
        } else {
            defaults.set(desktopPackages, forKey: "desktop.icons.\(id)")
            saveFolders()
        }
        if let saved = defaults.dictionary(forKey: "desktop.iconpos.\(id)") as? [String: [Double]] {
            iconPositions = saved.compactMapValues { $0.count == 2 ? CGPoint(x: $0[0], y: $0[1]) : nil }
        } else {
            saveIconPositions()
        }
    }

    private func start(backingScale: CGFloat) {
        guard let appState else { return }
        phase = .starting
        Task { await resolveStorageID() }
        let (w, h, density) = videoPixels(for: canvasSize, backingScale: backingScale)
        videoSize = CGSize(width: w, height: h)
        let video = appState.settings.video
        let stream = DesktopStream(config: .init(serial: serial, width: w, height: h, density: density,
                                                 bitRateMbps: max(video.bitRateMbps, 8),
                                                 maxFPS: video.maxFPS))
        let hub = frames
        stream.onFrame = { buffer in
            let box = PixelBox(buffer)
            DispatchQueue.main.async { MainActor.assumeIsolated { hub.publish(box.buffer) } }
        }
        stream.onVideoSize = { [weak self] size in
            Task { @MainActor in self?.videoSize = size }
        }
        stream.onDisplayID = { [weak self] id in
            Task { @MainActor in self?.displayReady(id) }
        }
        stream.onClipboard = { text in
            Task { @MainActor in
                let board = NSPasteboard.general
                if board.string(forType: .string) != text {
                    board.clearContents()
                    board.setString(text, forType: .string)
                }
            }
        }
        stream.onEnd = { [weak self] message in
            Task { @MainActor in self?.streamEnded(message) }
        }
        self.stream = stream
        // 여기서 깨우지 않는다 — 디스플레이가 준비되는 동안(수 초) 폰 화면·화면보호기가 켜져 보였다(실측).
        // 깨우기는 displayReady에서 wakelock·패널 끄기와 붙여서 한다.
        stream.start()
    }

    func stop() {
        pollTask?.cancel()
        resizeTask?.cancel()
        phoneStateTask?.cancel()
        phoneStateTask = nil
        notificationTask?.cancel()
        notificationTask = nil
        pollTask = nil
        stream?.onEnd = nil
        stream?.stop()
        stream = nil
        displayId = nil
        windows = []
        minimized = []
    }

    private func displayReady(_ id: Int) {
        displayId = id
        phase = .running
        startPolling()
        // 폰 전원·화면은 건드리지 않는다(아래 '폰 상태' 정책). 예전 버전이 남긴 wakelock만 정리한다.
        Task { [serial] in await ADB.releaseStaleDesktopWakelocks(serial: serial) }
        phoneStateTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refreshPhoneState()
                try? await Task.sleep(for: .seconds(5))
            }
        }
        notificationTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refreshNotifications()
                try? await Task.sleep(for: .seconds(30))
            }
        }
        // 기기가 확실히 온라인인 시점에 앱 목록을 받는다(못 받았으면 다시)
        if apps.isEmpty { reloadApps() }
        let queued = pending
        pending = []
        for entry in queued { open(entry.app, newInstance: entry.newInstance, restart: entry.restart) }
    }

    private func streamEnded(_ message: String?) {
        guard stream != nil else { return }
        stop()
        phase = .failed(message ?? String(localized: "기기와 연결이 끊어졌습니다"))
    }

    private func scheduleDisplayResize(backingScale: CGFloat) {
        resizeTask?.cancel()
        resizeTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(350))
            guard let self, !Task.isCancelled, let stream = self.stream else { return }
            let (w, h, _) = self.videoPixels(for: self.canvasSize, backingScale: backingScale)
            guard abs(CGFloat(w) - self.videoSize.width) > 8 || abs(CGFloat(h) - self.videoSize.height) > 8 else { return }
            stream.resizeDisplay(width: w, height: h)
        }
    }

    // MARK: 창 추적

    /// 창 목록 확인 주기.
    /* 변경 전 정책: 0.35초마다 `cmd activity stack list` — 데스크톱을 가만히 띄워 둬도 폰 system_server가
         코어 하나의 ~40%를 썼다(실측, 8코어 중).
       변경 후 정책: 조작(클릭·키·창 이동·앱 실행) 후 4초 동안만 0.35초, 그 밖에는 1.5초.
       영향 범위: 앱 안에서 스스로 창이 바뀌는 경우(다른 앱 열기 등) 화면 반영이 최대 1.5초 늦을 수 있다. */
    private func startPolling() {
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.poll()
                let active = Date().timeIntervalSince(self?.lastInteraction ?? .distantPast) < 4
                try? await Task.sleep(for: .milliseconds(active ? 350 : 1500))
            }
        }
    }

    /// 사용자 조작 시각 — 이 직후 잠깐은 창 목록을 촘촘히 확인한다.
    private(set) var lastInteraction = Date.distantPast

    func markActive() {
        lastInteraction = Date()
    }

    private func poll() async {
        guard let displayId, dragFrames.isEmpty,
              let result = try? await ADB.desktopWindows(serial: serial, displayId: displayId),
              dragFrames.isEmpty else { return }
        // 최소화된 창은 화면 밖에 치워 둔 채 같은 디스플레이에 남아 있다 — 목록에서 뺀다
        let parked = Set(minimized.map(\.id))
        let fresh = result.windows.filter { !hiding.contains($0.id) && !parked.contains($0.id) }
        if windows != fresh { windows = fresh }
        let visible = Set(windows.map(\.package))
        if !launching.isEmpty { launching.subtract(visible) }
        // 닫힌(목록에서 사라진) 최소화 창은 정리
        let alive = Set(result.windows.map(\.id))
        minimized.removeAll { !alive.contains($0.id) && !hiding.contains($0.id) }
    }

    /// 캔버스 위 앱 내용 영역(pt).
    func contentFrame(_ window: ADB.DesktopWindow) -> CGRect {
        if let drag = dragFrames[window.id] { return drag }
        let r = ratio
        let b = window.bounds
        return CGRect(x: b.minX / r, y: b.minY / r, width: b.width / r, height: b.height / r)
    }

    // MARK: 앱 실행

    func launch(_ app: AndroidApp, newInstance: Bool = false, restart: Bool = false) {
        if !newInstance, !restart {
            if let entry = minimized.first(where: { $0.package == app.package }) {
                restore(entry)
                return
            }
            if let window = windows.first(where: { $0.package == app.package }) {
                focus(window)
                return
            }
        }
        guard displayId != nil else {
            pending.append((app, newInstance, restart))
            return
        }
        open(app, newInstance: newInstance, restart: restart)
    }

    private func open(_ app: AndroidApp, newInstance: Bool, restart: Bool) {
        guard let displayId else { return }
        markActive()
        launching.insert(app.package)
        Task {
            do {
                // 폰 본 화면에 이미 떠 있는 앱은 먼저 데스크톱으로 옮긴다 — am start가 폰 화면에서 앞으로
                // 가져오는 바람에 폰에 앱이 튀어나오던 문제(사용자 보고)
                if !newInstance, !restart {
                    await ADB.moveAppToDisplay(serial: serial, package: app.package, displayId: displayId)
                }
                try await ADB.startApp(serial: serial, displayId: displayId, app: app,
                                       newInstance: newInstance, restart: restart)
                // 첫 프레임이 빨리 보이도록 잠깐 촘촘히 확인
                /* 변경 전 정책: 창이 목록에 잡히면(opening 해제) 그대로 끝냈다.
                   결함(실측): 폰 본 화면에서 fullscreen으로 떠 있던 태스크를 moveAppToDisplay로 옮기면
                   fullscreen windowing이 그대로 남는다 — am start --windowingMode 5는 살아 있는 기존
                   태스크에는 적용되지 않는다. fullscreen 태스크는 bounds가 디스플레이 전체라 제목줄 없이
                   캔버스를 덮고(크롬 전체화면 보고), cmd activity task resize도 무시된다.
                   변경 후 정책: 실행한 앱의 창이 fullscreen windowing으로 잡히면 1회만 -S로 재시작해
                   freeform 창으로 다시 띄운다(am start -S --windowingMode 5 — 실측: 크롬이
                   bounds=[54,60][2826,1580] 창으로 부활). 앱 안에서 스스로 전체화면이 된 경우와 구분하기
                   위해 최초 실행 경로에서만 한다(사용자가 연 앱은 창으로 뜨는 게 의도).
                   영향 범위: 데스크톱에서 앱을 여는 경로 전부(독·런처·바탕화면·CLI). */
                var retriedFullscreen = false
                for _ in 0..<8 {
                    try? await Task.sleep(for: .milliseconds(150))
                    await poll()
                    if !launching.contains(app.package) { break }
                    if !retriedFullscreen,
                       let w = windows.first(where: { $0.package == app.package }), w.fullscreen {
                        retriedFullscreen = true
                        try? await ADB.startApp(serial: serial, displayId: displayId, app: app,
                                                newInstance: false, restart: true)
                    }
                }
                // 다른 화면(폰 본 화면)에 이미 떠 있던 앱은 '앞으로 가져오기'만 되고 이 데스크톱엔 안 뜬다 — 옮겨 온다
                if launching.contains(app.package) {
                    await ADB.moveAppToDisplay(serial: serial, package: app.package, displayId: displayId)
                    try? await Task.sleep(for: .milliseconds(300))
                    await poll()
                }
            } catch {
                appState?.showError(String(localized: "\(app.displayLabel) 실행 실패: \(error.localizedDescription)"))
            }
            try? await Task.sleep(for: .seconds(3))
            launching.remove(app.package)
        }
    }

    // MARK: 창 조작

    func close(_ window: ADB.DesktopWindow) {
        windows.removeAll { $0.id == window.id }
        hiding.insert(window.id)
        Task {
            await ADB.closeWindow(serial: serial, taskId: window.id)
            hiding.remove(window.id)
        }
    }

    func minimize(_ window: ADB.DesktopWindow) {
        windows.removeAll { $0.id == window.id }
        minimized.append(Minimized(id: window.id, package: window.package, frame: window.bounds))
        hiding.insert(window.id)
        let park = CGRect(x: videoSize.width - 48, y: videoSize.height - 48,
                          width: window.bounds.width, height: window.bounds.height)
        let next = windows.first
        Task {
            await ADB.minimizeWindow(serial: serial, taskId: window.id, parkAt: park)
            hiding.remove(window.id)
            // 키 입력이 치운 창으로 가지 않게 다음 창을 앞으로
            if let next, let displayId {
                await ADB.focusWindow(serial: serial, displayId: displayId, component: next.component)
            }
        }
    }

    /// 홈: 떠 있는 창을 모두 최소화하고 바탕화면을 보여 준다(안드로이드 홈 버튼과 같은 뜻).
    func minimizeAll() {
        let all = windows
        guard !all.isEmpty else { return }
        windows = []
        for window in all {
            minimized.append(Minimized(id: window.id, package: window.package, frame: window.bounds))
            hiding.insert(window.id)
        }
        let size = videoSize
        Task {
            for window in all {
                await ADB.minimizeWindow(serial: serial, taskId: window.id,
                                         parkAt: CGRect(x: size.width - 48, y: size.height - 48,
                                                        width: window.bounds.width, height: window.bounds.height))
                hiding.remove(window.id)
            }
        }
    }

    func restore(_ entry: Minimized) {
        guard let displayId else { return }
        minimized.removeAll { $0.id == entry.id }
        Task {
            await ADB.restoreWindow(serial: serial, taskId: entry.id, displayId: displayId, frame: entry.frame)
            await poll()
        }
    }

    func toggleMaximize(_ window: ADB.DesktopWindow) {
        let target: CGRect
        if let previous = restoreFrames.removeValue(forKey: window.id) {
            target = previous
        } else {
            restoreFrames[window.id] = window.bounds
            let top = Self.titleBarHeight * ratio
            let bottom = Self.dockReserve * ratio
            target = CGRect(x: 0, y: top, width: videoSize.width, height: videoSize.height - top - bottom)
        }
        apply(window, bounds: target)
    }

    /// 창을 맨 앞으로 — 화면에서 먼저 올리고 기기에도 반영한다.
    func focus(_ window: ADB.DesktopWindow) {
        guard let displayId else { return }
        raiseLocally(window.id)
        Task { await ADB.focusWindow(serial: serial, displayId: displayId, component: window.component) }
    }

    /// 클릭으로 앞에 오는 창(기기는 터치로 스스로 올린다) — 화면 순서만 맞춘다.
    func raiseLocally(_ id: Int) {
        guard let index = windows.firstIndex(where: { $0.id == id }), index > 0 else { return }
        let window = windows.remove(at: index)
        windows.insert(window, at: 0)
    }

    /// 드래그/크기 조절이 끝난 창의 캔버스 영역(pt)을 기기에 적용한다.
    func commitDrag(_ window: ADB.DesktopWindow) {
        guard let frame = dragFrames[window.id] else { return }
        let r = ratio
        // 제목줄이 캔버스 밖으로 나가지 않게
        var px = CGRect(x: frame.minX * r, y: frame.minY * r, width: frame.width * r, height: frame.height * r)
        px.origin.y = max(px.minY, Self.titleBarHeight * r)
        px.origin.x = min(max(px.minX, -px.width + 80 * r), videoSize.width - 80 * r)
        px.origin.y = min(px.minY, videoSize.height - 40 * r)
        restoreFrames[window.id] = nil
        apply(window, bounds: px)
    }

    private func apply(_ window: ADB.DesktopWindow, bounds: CGRect) {
        markActive()
        if let index = windows.firstIndex(where: { $0.id == window.id }) {
            windows[index] = ADB.DesktopWindow(id: window.id, package: window.package,
                                               component: window.component, bounds: bounds.integral,
                                               fullscreen: window.fullscreen)
        }
        dragFrames[window.id] = nil
        Task { await ADB.moveWindow(serial: serial, taskId: window.id, to: bounds) }
    }

    // MARK: 입력

    var input: DesktopStream? { stream }

    // MARK: 클립보드·파일 주고받기(맥 ⇄ 폰)

    /* 변경 전 정책: 텍스트는 기기→맥만 자동 동기(onClipboard)됐고, 맥→기기 ⌘V는 앱 창(DesktopVideoView)이
       first responder일 때만 동작했다. 파일은 본체 화면의 '파일 전송'으로만 맥→폰 push했고 ⌘C/⌘V와 무관했다.
       변경 후 정책: 데스크톱 창 어디서나(DesktopKeyMonitor) ⌘C/⌘X/⌘V —
         ⌘C/⌘X: 기기에 Ctrl+C/X를 보낸다(기기 클립보드가 바뀌면 onClipboard가 맥 클립보드로 자동 동기화).
         ⌘V: 맥 클립보드에 파일 URL(파인더 ⌘C)이 있으면 폰 Download으로 전송, 이미지(png/tiff)면 png 파일로
           만들어 전송, 텍스트면 기기 클립보드로 넣어 바로 붙여넣는다.
         폰→맥 파일: 바탕화면 우클릭 '맥으로 파일 가져오기…'에서 Download 파일을 골라 맥 클립보드에 넣는다
           (파인더 등 맥에서 ⌘V로 붙여넣는다). 기기 클립보드의 파일 URI는 읽을 방법이 없어(scrcpy는 텍스트만
           보내고 shell은 다른 앱 clipboard 접근이 막힘) 이 경로로 제공한다.
       변경 이유: 대장님 요청 — DeX 데스크톱과 맥 간 양방향 클립보드·파일 복사/붙여넣기(⌘C/⌘V).
       영향 범위: 데스크톱 창의 ⌘C/⌘X/⌘V, 바탕화면 우클릭 메뉴, 상단 전송 배너. 미러 창(scrcpy)은 무관. */

    /// 폰 Download 폴더의 파일 한 건(폰→맥 선택창용).
    struct PhoneFile: Identifiable, Hashable {
        let name: String
        let size: Int
        var id: String { name }
        var remotePath: String { "/sdcard/Download/\(name)" }
    }

    /// 전송 배너 — 진행 중(active)이면 인디케이터, 끝나면 결과를 4초 보여 주고 사라진다.
    private(set) var transferActive = false
    private(set) var transferMessage: String?
    private var transferTask: Task<Void, Never>?
    private var transferHideTask: Task<Void, Never>?

    /// ⌘V — 맥 클립보드를 기기에 붙여넣는다. 파일이면 폰 Download으로, 이미지면 png로 만들어 전송한다.
    func pasteFromMac() {
        let board = NSPasteboard.general
        if let urls = board.readObjects(forClasses: [NSURL.self],
                                        options: [.urlReadingFileURLsOnly: true]) as? [URL], !urls.isEmpty {
            sendFilesToPhone(urls)
            return
        }
        if let text = board.string(forType: .string), !text.isEmpty {
            stream?.setClipboard(text, paste: true)
            return
        }
        // 이미지(스크린샷 ⌘⇧⌃Ⓢ 등) — png 파일로 만들어 전송. 텍스트·파일이 없을 때만.
        if let png = board.data(forType: .png) ?? (board.data(forType: .tiff).flatMap {
            NSBitmapImageRep(data: $0)?.representation(using: .png, properties: [:])
        }) {
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyyMMdd-HHmmss"
            let stamp = formatter.string(from: Date())
            let url = FileManager.default.temporaryDirectory.appending(path: "macdroid-clipboard-\(stamp).png")
            if (try? png.write(to: url)) != nil { sendFilesToPhone([url]) }
        }
    }

    /// ⌘C — 기기에 Ctrl+C. 기기 앱이 복사하면 클립보드 변경이 맥으로 자동 동기된다.
    func copyFromDevice() { stream?.pressKey(31, metaState: 0x3000) }   // KEYCODE_C + CTRL
    /// ⌘X — 기기에 Ctrl+X.
    func cutFromDevice() { stream?.pressKey(52, metaState: 0x3000) }    // KEYCODE_X + CTRL

    /// 맥 파일들을 폰 Download으로 보낸다(기존 파일 전송과 같은 목적지·문구).
    func sendFilesToPhone(_ files: [URL]) {
        guard !files.isEmpty else { return }
        transferTask?.cancel()
        transferHideTask?.cancel()
        transferActive = true
        transferMessage = String(localized: "파일 전송 중… \(files.count)개")
        transferTask = Task { [serial] in
            var failures: [String] = []
            for file in files {
                do { try await ADB.push(serial: serial, file: file) }
                catch { failures.append(file.lastPathComponent) }
            }
            endTransfer(failures.isEmpty
                        ? String(localized: "전송 완료: 폰의 Download 폴더에 저장됨")
                        : String(localized: "전송 실패: \(failures.joined(separator: ", "))"))
        }
    }

    /// 폰 Download 폴더의 파일 목록(빈 배열 = 폴더가 비었음, nil = 읽기 실패).
    func listDownloadFiles() async -> [PhoneFile]? {
        // ls -la의 한 줄: 권한 링크 소유자 그룹 크기 날짜 시간 이름(이름에는 공백이 있을 수 있다)
        guard let out = try? await ADB.shell(serial: serial, "ls -la /sdcard/Download") else { return nil }
        return out.split(separator: "\n").compactMap { line -> PhoneFile? in
            let parts = line.split(separator: " ", maxSplits: 7, omittingEmptySubsequences: true)
            guard parts.count == 8, parts[0].hasPrefix("-"), let size = Int(parts[4]),
                  !parts[7].hasPrefix("."), parts[7] != "total" else { return nil }
            return PhoneFile(name: String(parts[7]), size: size)
        }
        .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// 고른 Download 파일들을 맥 클립보드에 넣는다 — 파인더 등에서 ⌘V로 붙여넣는다.
    func copyToMacClipboard(_ files: [PhoneFile]) {
        guard !files.isEmpty else { return }
        transferTask?.cancel()
        transferHideTask?.cancel()
        transferActive = true
        transferMessage = String(localized: "가져오는 중… \(files.count)개")
        transferTask = Task { [serial] in
            // 받는 곳: 앱 지원 폴더의 임시 폴더(맥의 기존 파일을 덮어쓰지 않게)
            let dir = Binaries.appSupport.appending(path: "Transfers/\(UUID().uuidString)", directoryHint: .isDirectory)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            var copied: [URL] = []
            var failures: [String] = []
            for file in files {
                do {
                    try await ADB.pull(serial: serial, remote: file.remotePath, to: dir)
                    copied.append(dir.appending(path: file.name))
                } catch { failures.append(file.name) }
            }
            if !copied.isEmpty {
                let board = NSPasteboard.general
                board.clearContents()
                board.writeObjects(copied as [NSURL])
            }
            if copied.isEmpty {
                endTransfer(String(localized: "가져오기 실패: \(failures.joined(separator: ", "))"))
            } else if failures.isEmpty {
                endTransfer(String(localized: "\(copied.count)개 파일을 맥 클립보드에 넣었습니다 — 맥에서 ⌘V로 붙여넣으세요"))
            } else {
                endTransfer(String(localized: "가져오기 실패: \(failures.joined(separator: ", "))"))
            }
        }
    }

    /// 전송 배너를 결과 상태로 바꾸고 4초 뒤 지운다.
    private func endTransfer(_ message: String) {
        transferActive = false
        transferMessage = message
        transferHideTask?.cancel()
        transferHideTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled else { return }
            self?.transferMessage = nil
        }
    }

    func back() {
        stream?.pressKey(4)   // KEYCODE_BACK — 이 디스플레이의 포커스 창으로 간다
    }

    /// 특정 창의 뒤로가기(제목줄 버튼) — 키 입력은 포커스 창으로 가므로 맨 앞 창이 아니면 먼저 올린다.
    func back(windowID: Int) {
        if let window = windows.first(where: { $0.id == windowID }) { back(window) } else { back() }
    }

    func back(_ window: ADB.DesktopWindow) {
        guard windows.first?.id != window.id else {
            back()
            return
        }
        focus(window)
        Task {
            try? await Task.sleep(for: .milliseconds(250))
            back()
        }
    }

    // MARK: 폰 상태

    /* 변경 전 정책: 데스크톱이 떠 있는 동안 폰이 잠들지 않게 붙잡고(wakelock), 폰 본 화면 패널을 꺼 두고, 잠들면
         자동으로 깨우고, 닫을 때 다시 재웠다.
       변경 후 정책: 폰 본체의 전원·화면 상태는 MacDroid가 절대 바꾸지 않는다. 폰이 스스로 잠들면(화면 꺼짐 시간 등)
         데스크톱 화면도 멈추고, 데스크톱에 "폰 화면이 꺼져 있음" 안내와 [폰 깨우기] 버튼을 띄운다 — 깨우기는 사용자가
         누를 때만.
       변경 이유: 사용자 요구 "본체에는 전혀 영향 없어야 한다" — 패널 끄기로 폰이 가끔 까만 화면이 됐고(실측),
         wakelock도 폰을 확실히 붙잡지 못했다(실측: wakelock을 잡고도 Dozing).
       영향 범위: 데스크톱 세션 동안의 폰 전원 동작 전부. 폰이 잠들면 데스크톱은 깨울 때까지 멈춘다. */

    /// 조작할 때(클릭·키) 폰 상태를 바로 다시 확인한다(4초에 한 번) — 깨우지는 않는다.
    func nudgeAwake() {
        markActive()
        guard Date().timeIntervalSince(lastAwakeCheck) > 4 else { return }
        lastAwakeCheck = Date()
        Task { await refreshPhoneState() }
    }

    func refreshPhoneState() async {
        guard let out = try? await ADB.shell(serial: serial, "dumpsys power | grep -m1 mWakefulness=") else { return }
        let asleep = !out.contains("Awake")
        if asleep != phoneAsleep { phoneAsleep = asleep }
    }

    /// 사용자가 [폰 깨우기]를 눌렀을 때만.
    func wakePhone() {
        Task {
            await ADB.wakeIfAsleep(serial: serial)
            try? await Task.sleep(for: .milliseconds(500))
            await refreshPhoneState()
        }
    }

    // MARK: 한글 입력 조건(본체 잠금)

    /* 정책(한글 IME 안내): 안드로이드 IME는 한 번에 한 디스플레이만 담당한다(실측 — 인사이트 macdex-i-ime).
       폰 본체 화면이 켜져 있으면 IME가 본체에 붙어 데스크톱 물리 키보드(uhid)의 한글이 조합되지 않고
       영어만 입력된다. 본체를 잠그면(화면 끔) IME가 데스크톱 디스플레이로 붙어 한/영(Shift+Space)·조합이 동작한다.
       키보드 입력이 있는데 본체가 깨어 있으면 배너로 안내하고, [본체 잠그기]는 사용자가 누를 때만 잠근다. */
    /// 한글 입력에 본체 잠금이 필요하다는 안내 배너 표시 여부.
    private(set) var showIMEHint = false

    /// 데스크톱 창에서 키보드 입력이 시작됐을 때 — 본체가 깨어 있으면(=한글이 안 되는 상태) 안내를 띄운다.
    func markKeyboardUsed() {
        if !phoneAsleep { showIMEHint = true }
    }

    /// 사용자가 [본체 잠그기]를 눌렀을 때만.
    func lockPhoneNow() {
        Task {
            await ADB.sleepIfAwake(serial: serial)
            try? await Task.sleep(for: .milliseconds(600))
            await refreshPhoneState()
            if phoneAsleep { showIMEHint = false }
        }
    }

    func dismissIMEHint() {
        showIMEHint = false
    }

    // MARK: 상태표시줄

    func refreshNotifications() async {
        notifications = await ADB.notifications(serial: serial)
        bluetoothOn = await ADB.bluetoothOn(serial: serial)
    }

    func dismiss(_ notification: ADB.PhoneNotification) {
        notifications.removeAll { $0.id == notification.id }
        Task { await ADB.dismissNotification(serial: serial, key: notification.id) }
    }

    // MARK: 창 스냅

    /* 정책(창 분할 자동 스냅): 제목줄을 끌어 포인터가 캔버스 가장자리에 닿으면
       왼쪽/오른쪽 = 절반, 위 = 최대화, 왼쪽·오른쪽 위/아래 모서리(60pt) = 1/4. 놓으면 그 자리로 맞추고
       이전 크기를 기억한다 — 다시 끌어내거나 초록 버튼을 누르면 원래 크기로. 가장자리에서 벗어나면 미리보기가 사라진다.
       영향 범위: 데스크톱 앱 창 제목줄 드래그. */
    func snapTarget(at point: CGPoint) -> CGRect? {
        let w = canvasSize.width, h = canvasSize.height - Self.dockReserve
        guard w > 0, h > 0 else { return nil }
        let edge: CGFloat = 6, corner: CGFloat = 60
        let left = point.x <= edge, right = point.x >= w - edge, top = point.y <= edge
        if left || right {
            let x = left ? 0 : w / 2
            if point.y <= corner { return CGRect(x: x, y: 0, width: w / 2, height: h / 2) }
            if point.y >= h - corner { return CGRect(x: x, y: h / 2, width: w / 2, height: h / 2) }
            return CGRect(x: x, y: 0, width: w / 2, height: h)
        }
        if top { return CGRect(x: 0, y: 0, width: w, height: h) }
        return nil
    }

    /// 스냅 자리(제목줄 포함, pt)에 창을 맞춘다.
    func snap(_ window: ADB.DesktopWindow, to rect: CGRect) {
        let r = ratio
        if restoreFrames[window.id] == nil { restoreFrames[window.id] = window.bounds }
        let content = CGRect(x: rect.minX * r, y: (rect.minY + Self.titleBarHeight) * r,
                             width: rect.width * r, height: (rect.height - Self.titleBarHeight) * r)
        apply(window, bounds: content)
    }

    /// 스냅/최대화 상태에서 끌기 시작하면 원래 크기로 돌아간 영역(pt) — 포인터가 같은 비율 위치를 잡게.
    func unsnappedFrame(_ window: ADB.DesktopWindow, grabbing point: CGPoint) -> CGRect? {
        guard let previous = restoreFrames[window.id] else { return nil }
        let r = ratio
        let current = contentFrame(window)
        let size = CGSize(width: previous.width / r, height: previous.height / r)
        let fraction = current.width > 0 ? (point.x - current.minX) / current.width : 0.5
        return CGRect(x: point.x - size.width * fraction, y: current.minY, width: size.width, height: size.height)
    }

    /// 폰 시스템 화면(Wi-Fi 등)을 데스크톱 창으로 연다.
    func openSystemPage(_ action: String, package: String = "com.android.settings") {
        guard let displayId else { return }
        Task {
            // 폰 화면에 떠 있던 설정 창이 폰에서 앞으로 나오지 않게 먼저 데스크톱으로
            await ADB.moveAppToDisplay(serial: serial, package: package, displayId: displayId)
            await ADB.openSystemPage(serial: serial, displayId: displayId, action: action)
            try? await Task.sleep(for: .milliseconds(300))
            await poll()
        }
    }

    // MARK: 앱 목록·독·바탕화면

    /// 앱 목록(실제 이름·아이콘) 받기.
    /* 변경 전 정책: 데스크톱 시작 시 한 번만 받았다 — 그 순간 기기가 잠깐 offline이면(앱 재시작 직후 재연결 등)
         빈 목록으로 끝나 앱 서랍이 계속 비어 있었다.
       변경 후 정책: 가상 디스플레이가 준비된 뒤(기기 온라인 확정) 받고, 비어 있으면 앱 서랍을 열 때마다 다시 받는다.
       영향 범위: 앱 서랍·독·바탕화면 아이콘의 이름/아이콘. */
    func reloadApps() {
        guard !appsLoading else { return }
        appsLoading = true
        Task {
            var loaded: [AndroidApp] = []
            if let indexed = await AppCatalog.loadIndex(serial: serial) {
                loaded = indexed
            } else if let listed = try? await ADB.installedApps(serial: serial) {
                loaded = listed
            }
            if !loaded.isEmpty { apps = loaded }
            appsLoading = false
            appsLoaded = true
        }
    }

    func app(for package: String) -> AndroidApp {
        apps.first { $0.package == package } ?? AndroidApp(package: package, apkPath: nil)
    }

    func isRunning(_ package: String) -> Bool {
        windows.contains { $0.package == package } || minimized.contains { $0.package == package }
    }

    /// 독: 고정 앱 + 고정 안 된 실행 중 앱.
    var dockItems: [String] {
        // 앱 목록을 받은 뒤에는 기기에 없는 기본 고정 앱을 감춘다
        var items = appsLoaded && !apps.isEmpty
            ? dockPackages.filter { package in apps.contains { $0.package == package } }
            : dockPackages
        for package in windows.map(\.package) + minimized.map(\.package) where !items.contains(package) {
            items.append(package)
        }
        return items
    }

    func isPinned(_ package: String) -> Bool { dockPackages.contains(package) }
    func isOnDesktop(_ package: String) -> Bool {
        desktopPackages.contains(package) || folders.values.contains { $0.packages.contains(package) }
    }

    func togglePin(_ package: String) {
        if let index = dockPackages.firstIndex(of: package) {
            dockPackages.remove(at: index)
        } else {
            dockPackages.append(package)
        }
        UserDefaults.standard.set(dockPackages, forKey: "desktop.dock.\(storageID)")
    }

    func toggleDesktop(_ package: String) {
        if let index = desktopPackages.firstIndex(of: package) {
            desktopPackages.remove(at: index)
            iconPositions[package] = nil
            saveIconPositions()
        } else if let folderID = folders.first(where: { $0.value.packages.contains(package) })?.key {
            folders[folderID]?.packages.removeAll { $0 == package }
            saveFolders()
        } else {
            desktopPackages.append(package)
        }
        saveDesktopItems()
    }

    private func saveDesktopItems() {
        UserDefaults.standard.set(desktopPackages, forKey: "desktop.icons.\(storageID)")
    }

    // MARK: 바탕화면 여러 개 선택·폴더

    /* 정책(바탕화면 다중 선택·폴더):
       - 여러 항목을 한 번에 바탕화면에서 지운다(앱 바로가기만 지움 — 앱 삭제 아님, 폴더는 안의 바로가기째).
       - 폴더 = 바탕화면 항목 "folder:<id>"(이름 + 앱 목록, 기기별 UserDefaults desktop.folders.<시리얼>).
         선택 항목으로 만들기 / 빈 폴더 만들기 / 아이콘을 폴더 위에 놓아 넣기 / 폴더에서 빼면 바탕화면으로 /
         폴더 해제 시 안의 앱은 바탕화면으로 돌아간다.
       영향 범위: 바탕화면 아이콘 영역만(독·앱 서랍과 무관). */
    static func isFolder(_ item: String) -> Bool { item.hasPrefix("folder:") }

    func removeDesktopItems(_ items: Set<String>) {
        guard !items.isEmpty else { return }
        desktopPackages.removeAll { items.contains($0) }
        for item in items {
            iconPositions[item] = nil
            if Self.isFolder(item) { folders[item] = nil }
        }
        saveDesktopItems()
        saveFolders()
        saveIconPositions()
    }

    /// 폴더 만들기 — 주어진 앱(바탕화면 항목)을 담고, 첫 항목 자리(또는 지정 위치)에 둔다. 새 폴더 id를 돌려준다.
    @discardableResult
    func createFolder(with items: [String] = [], at point: CGPoint? = nil) -> String {
        let id = "folder:" + UUID().uuidString
        var packages: [String] = []
        for item in items {
            if Self.isFolder(item) {
                packages += folders[item]?.packages ?? []
                folders[item] = nil
            } else {
                packages.append(item)
            }
        }
        let existing = Set(folders.values.map(\.name))
        var name = String(localized: "새 폴더")
        var n = 2
        while existing.contains(name) { name = String(localized: "새 폴더 \(n)"); n += 1 }
        folders[id] = DesktopFolder(name: name, packages: packages)
        let anchor = point ?? items.first.flatMap { iconPositions[$0] }
        let index = items.compactMap { desktopPackages.firstIndex(of: $0) }.min() ?? desktopPackages.count
        desktopPackages.removeAll { items.contains($0) }
        desktopPackages.insert(id, at: min(index, desktopPackages.count))
        for item in items { iconPositions[item] = nil }
        if let anchor { iconPositions[id] = anchor }
        saveDesktopItems()
        saveFolders()
        saveIconPositions()
        return id
    }

    func renameFolder(_ id: String, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, folders[id] != nil else { return }
        folders[id]?.name = trimmed
        saveFolders()
    }

    /// 바탕화면 앱들을 폴더에 넣는다(폴더끼리는 합치지 않는다).
    func addToFolder(_ id: String, items: [String]) {
        guard folders[id] != nil else { return }
        let apps = items.filter { !Self.isFolder($0) && $0 != id }
        guard !apps.isEmpty else { return }
        for app in apps where !(folders[id]?.packages.contains(app) ?? true) {
            folders[id]?.packages.append(app)
        }
        desktopPackages.removeAll { apps.contains($0) }
        for app in apps { iconPositions[app] = nil }
        saveDesktopItems()
        saveFolders()
        saveIconPositions()
    }

    /// 폴더에서 빼서 바탕화면으로.
    func removeFromFolder(_ id: String, package: String) {
        folders[id]?.packages.removeAll { $0 == package }
        if !desktopPackages.contains(package) { desktopPackages.append(package) }
        saveDesktopItems()
        saveFolders()
    }

    /// 폴더 해제 — 안의 앱은 바탕화면으로 돌아간다.
    func ungroupFolder(_ id: String) {
        guard let folder = folders[id] else { return }
        let index = desktopPackages.firstIndex(of: id) ?? desktopPackages.count
        desktopPackages.removeAll { $0 == id }
        let back = folder.packages.filter { !desktopPackages.contains($0) }
        desktopPackages.insert(contentsOf: back, at: min(index, desktopPackages.count))
        folders[id] = nil
        iconPositions[id] = nil
        saveDesktopItems()
        saveFolders()
        saveIconPositions()
    }

    private func saveFolders() {
        let data = try? JSONEncoder().encode(folders)
        UserDefaults.standard.set(data, forKey: "desktop.folders.\(storageID)")
    }

    private static func loadFolders(_ id: String) -> [String: DesktopFolder] {
        guard let data = UserDefaults.standard.data(forKey: "desktop.folders.\(id)"),
              let decoded = try? JSONDecoder().decode([String: DesktopFolder].self, from: data) else { return [:] }
        return decoded
    }

    /// 바탕화면 아이콘 칸 크기(pt).
    static let iconCell = CGSize(width: 92, height: 98)

    /// 아이콘 위치: 저장된 자리, 없으면 다른 아이콘과 겹치지 않는 첫 격자 칸(세로 우선).
    func iconLayout(in size: CGSize) -> [String: CGPoint] {
        let cell = Self.iconCell
        let rows = max(Int((size.height - Self.dockReserve - 16) / cell.height), 1)
        var result: [String: CGPoint] = [:]
        var taken = desktopPackages.compactMap { iconPositions[$0] }
        var slot = 0
        for item in desktopPackages {
            if let saved = iconPositions[item] {
                result[item] = saved
                continue
            }
            while true {
                let point = CGPoint(x: 12 + CGFloat(slot / rows) * cell.width, y: 12 + CGFloat(slot % rows) * cell.height)
                slot += 1
                if !taken.contains(where: { abs($0.x - point.x) < cell.width * 0.6 && abs($0.y - point.y) < cell.height * 0.6 }) {
                    result[item] = point
                    taken.append(point)
                    break
                }
                if slot > 2000 { result[item] = point; break }
            }
        }
        return result
    }

    /// 폰 캘린더 앱을 그 날짜로 연다.
    func openCalendar(at date: Date) {
        guard let displayId else { return }
        let ms = Int64(date.timeIntervalSince1970 * 1000)
        Task {
            await ADB.moveAppToDisplay(serial: serial, package: "com.samsung.android.calendar", displayId: displayId)
            _ = try? await ADB.shell(serial: serial,
                "am start --display \(displayId) --windowingMode 5 -a android.intent.action.VIEW -d content://com.android.calendar/time/\(ms)")
            try? await Task.sleep(for: .milliseconds(300))
            await poll()
        }
    }

    /// 바탕화면 아이콘 자유 배치.
    /* 변경 전 정책: 바탕화면 아이콘은 추가한 순서대로 왼쪽 위부터 세로 격자에 고정 배치(옮길 수 없음).
       변경 후 정책: 끌어다 놓은 위치(pt)를 기기별로 저장해 그 자리에 둔다. 옮긴 적 없는 아이콘은 비어 있는 격자 칸에
         자동 배치. 바탕화면 우클릭 '아이콘 정렬'로 전부 격자로 되돌린다.
       영향 범위: 바탕화면 아이콘 표시 위치(UserDefaults desktop.iconpos.<기기 시리얼>). */
    func setIconPosition(_ package: String, _ point: CGPoint) {
        iconPositions[package] = point
        saveIconPositions()
    }

    func resetIconPositions() {
        iconPositions = [:]
        saveIconPositions()
    }

    private func saveIconPositions() {
        let raw = iconPositions.mapValues { [Double($0.x), Double($0.y)] }
        UserDefaults.standard.set(raw, forKey: "desktop.iconpos.\(storageID)")
    }

    func setWallpaper(_ url: URL?) {
        wallpaperPath = url?.path
        UserDefaults.standard.set(wallpaperPath, forKey: "desktop.wallpaper")
    }

    /// 독 아이콘 클릭: 최소화돼 있으면 복원, 떠 있으면 앞으로, 없으면 실행.
    func activate(_ package: String) {
        launch(app(for: package))
    }

    func closeAll(_ package: String) {
        for window in windows where window.package == package { close(window) }
    }

    func label(for package: String) -> String {
        if let app = apps.first(where: { $0.package == package }), let label = app.label { return label }
        if let cached = labels[package] { return cached }
        let file = Binaries.iconCache.appending(path: package + ".label")
        let label = (try? String(contentsOf: file, encoding: .utf8))
            ?? AndroidApp(package: package, apkPath: nil).fallbackLabel
        labels[package] = label
        return label
    }

    func icon(for package: String) -> NSImage? {
        if let cached = icons[package] { return cached }
        let url = apps.first(where: { $0.package == package })?.iconURL
            ?? Binaries.iconCache.appending(path: package + ".png")
        let image = NSImage(contentsOf: url)
        if let image { icons[package] = image }
        return image
    }
}

// MARK: - 프레임 배포

/// 디코드된 프레임(IOSurface)을 창마다 있는 잘라 그리기 뷰에 나눠 준다 — SwiftUI 상태를 거치지 않는다(60fps).
@MainActor
final class FrameHub {
    private let views = NSHashTable<DesktopVideoView>.weakObjects()
    private var recent: [CVPixelBuffer] = []
    private(set) var surface: IOSurface?
    private(set) var pixelSize: CGSize = .zero

    func register(_ view: DesktopVideoView) {
        views.add(view)
        if let surface { view.show(surface, pixelSize: pixelSize) }
    }

    func publish(_ buffer: CVPixelBuffer) {
        guard let unmanaged = CVPixelBufferGetIOSurface(buffer) else { return }
        let surface = unmanaged.takeUnretainedValue() as IOSurface
        // 화면에 붙어 있는 동안 버퍼가 풀로 돌아가 덮어써지지 않게 최근 몇 개를 잡아 둔다
        recent.append(buffer)
        if recent.count > 3 { recent.removeFirst() }
        self.surface = surface
        pixelSize = CGSize(width: CVPixelBufferGetWidth(buffer), height: CVPixelBufferGetHeight(buffer))
        for view in views.allObjects { view.show(surface, pixelSize: pixelSize) }
    }
}

private final class PixelBox: @unchecked Sendable {
    let buffer: CVPixelBuffer
    init(_ buffer: CVPixelBuffer) { self.buffer = buffer }
}

/// 바탕화면 폴더.
struct DesktopFolder: Codable, Equatable {
    var name: String
    var packages: [String]
}
