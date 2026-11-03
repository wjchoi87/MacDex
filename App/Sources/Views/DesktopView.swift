import SwiftUI
import AppKit

/// MacDroid 데스크톱 — 우리만의 Mac 스타일 데스크톱 환경.
/* 정책: "모니터에 안드로이드 런처" 방식(삼성 의존)은 폐기했다. 대신 이 창이
   데스크톱 셸이다 — 맥식 메뉴바(시계·배터리), 맥식 독(거리 기반 확대 애니메이션,
   실행 중 점, 런치 바운스), 런치패드(블러+검색). 앱은 각자 독립 창(가상 디스플레이)으로
   떠서 진짜 맥에서 앱 여러 개 쓰는 경험을 준다. 기기 무관. */
struct DesktopView: View {
    @Environment(AppState.self) private var appState

    let serial: String

    @State private var apps: [AndroidApp] = []
    @State private var icons: [String: NSImage] = [:]
    @State private var loading = true
    @State private var showLaunchpad = false
    @State private var launchpadSearch = ""
    @State private var mouseX: CGFloat?
    @State private var iconCenters: [String: CGFloat] = [:]   // 패키지 → 독 아이콘 중심 X(전역)
    @State private var bouncingPackage: String?

    private var device: Device? { appState.device(for: serial) }

    /// 독에 띄울 항목: 런치패드 + 실행 중/최근 앱 (최근 순, 최대 9개).
    private var dockApps: [AndroidApp] {
        var seen = Set<String>()
        var list: [AndroidApp] = []
        let running = appState.sessions
            .filter { $0.deviceSerial == serial && $0.mode == .app }
            .compactMap { session in apps.first { $0.package == session.id.split(separator: "|").last.map(String.init) } }
        let recents = (appState.dexOpenedApps[serial] ?? []).reversed()
        for app in (running + recents) where !seen.contains(app.package) {
            seen.insert(app.package)
            list.append(app)
        }
        if let settings = apps.first(where: { $0.package == "com.android.settings" }), !seen.contains("com.android.settings") {
            list.append(settings)
        }
        return Array(list.prefix(9))
    }

    private var runningPackages: Set<String> {
        Set(appState.sessions
            .filter { $0.deviceSerial == serial && $0.mode == .app }
            .compactMap { $0.id.split(separator: "|").last.map(String.init) })
    }

    private var launchpadFiltered: [AndroidApp] {
        guard !launchpadSearch.isEmpty else { return apps }
        let query = launchpadSearch.lowercased()
        return apps.filter {
            $0.package.lowercased().contains(query) || $0.displayLabel.lowercased().contains(query)
        }
    }

    var body: some View {
        ZStack {
            wallpaper

            VStack(spacing: 0) {
                menuBar
                Spacer()
                if loading {
                    ProgressView("앱 목록 불러오는 중…")
                        .padding()
                } else if apps.isEmpty {
                    Text("설치된 앱이 없습니다")
                        .foregroundStyle(.white.opacity(0.7))
                }
                Spacer()
                dock
            }

            if showLaunchpad {
                launchpad
                    .transition(.opacity.combined(with: .scale(scale: 0.98)))
            }
        }
        .overlay(alignment: .bottom) {
            StatusBanner().padding(.bottom, 96)
        }
        .frame(minWidth: 980, idealWidth: 1280, minHeight: 620, idealHeight: 800)
        .task {
            await load()
        }
        .animation(.spring(response: 0.35, dampingFraction: 0.85), value: showLaunchpad)
    }

    // MARK: 배경

    private var wallpaper: some View {
        ZStack {
            LinearGradient(colors: [Color(red: 0.05, green: 0.09, blue: 0.24),
                                    Color(red: 0.10, green: 0.28, blue: 0.66),
                                    Color(red: 0.18, green: 0.62, blue: 0.92)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
            Circle().fill(Color.white.opacity(0.06)).frame(width: 420).offset(x: -180, y: -140)
            Circle().fill(Color.white.opacity(0.05)).frame(width: 300).offset(x: 220, y: 160)
            Circle().fill(Color.white.opacity(0.04)).frame(width: 520).offset(x: 60, y: -220)
            VStack {
                Spacer()
                Text("MacDroid")
                    .font(.system(size: 90, weight: .bold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.08))
                    .padding(.bottom, 110)
            }
        }
        .ignoresSafeArea()
    }

    // MARK: 메뉴바

    private var menuBar: some View {
        HStack(spacing: 14) {
            HStack(spacing: 6) {
                Image(systemName: "dock.rectangle")
                Text("MacDroid").fontWeight(.semibold)
            }
            Text(device?.displayModel ?? serial)
                .foregroundStyle(.white.opacity(0.75))
            if let battery = device?.batteryLevel {
                Label("\(battery)%", systemImage: (device?.isCharging ?? false) ? "battery.100.bolt" : "battery.100")
                    .foregroundStyle(.white.opacity(0.75))
            }
            Spacer()
            TimelineView(.periodic(from: .now, by: 30)) { context in
                Text(context.date.formatted(.dateTime.hour().minute()))
                    .monospacedDigit()
            }
        }
        .font(.callout)
        .foregroundStyle(.white)
        .padding(.horizontal, 16)
        .frame(height: 30)
        .background(.black.opacity(0.35))
    }

    // MARK: 독

    private var dock: some View {
        HStack(spacing: 10) {
            // 런치패드 토글(맥의 Launchpad)
            DockIconView(scale: magnification(for: "__launchpad__"),
                         isRunning: false,
                         bouncing: false) {
                withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                    showLaunchpad.toggle()
                }
            } content: {
                Image(systemName: "square.grid.2x2")
                    .font(.system(size: 26))
                    .foregroundStyle(.white)
            }
            .onGeometryChangeStore(key: "__launchpad__", into: $iconCenters)

            Rectangle()
                .fill(.white.opacity(0.25))
                .frame(width: 1, height: 40)

            ForEach(dockApps) { app in
                DockIconView(scale: magnification(for: app.package),
                             isRunning: runningPackages.contains(app.package),
                             bouncing: bouncingPackage == app.package) {
                    launch(app)
                } content: {
                    dockImage(app)
                }
                .onGeometryChangeStore(key: app.package, into: $iconCenters)
                .help("\(app.displayLabel)\n\(app.package)")
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 24))
        .overlay(RoundedRectangle(cornerRadius: 24).strokeBorder(.white.opacity(0.18)))
        .shadow(color: .black.opacity(0.35), radius: 18, y: 8)
        .padding(.bottom, 14)
        .onContinuousHover { phase in
            switch phase {
            case .active(let location):
                mouseX = location.x
            case .ended:
                mouseX = nil
            }
        }
        .animation(.spring(response: 0.22, dampingFraction: 0.8), value: mouseX)
    }

    /// 맥 독의 시그니처 확대: 커서와 아이콘 중심의 거리로 배율 결정.
    private func magnification(for key: String) -> CGFloat {
        guard let mouseX, let center = iconCenters[key] else { return 1 }
        let distance = abs(mouseX - center)
        guard distance < 110 else { return 1 }
        let influence = 1 - distance / 110          // 0~1
        return 1 + 0.55 * influence * influence     // 최대 1.55배, 포물선 감쇠
    }

    @ViewBuilder
    private func dockImage(_ app: AndroidApp) -> some View {
        if let image = icons[app.package] {
            Image(nsImage: image).resizable().frame(width: 34, height: 34)
        } else {
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.accentColor.gradient)
                .frame(width: 34, height: 34)
                .overlay(Text(String(app.displayLabel.prefix(1)))
                    .font(.system(size: 16, weight: .bold, design: .rounded))
                    .foregroundStyle(.white))
        }
    }

    // MARK: 런치패드

    private var launchpad: some View {
        ZStack {
            Rectangle().fill(.ultraThinMaterial)
                .ignoresSafeArea()
            VStack(spacing: 18) {
                HStack {
                    Spacer()
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("앱 검색", text: $launchpadSearch)
                        .textFieldStyle(.plain)
                        .frame(width: 220)
                    Spacer()
                }
                .padding(8)
                .background(.white.opacity(0.25), in: Capsule())

                ScrollView {
                    LazyVGrid(columns: Array(repeating: GridItem(.fixed(104), spacing: 18), count: 7), spacing: 22) {
                        ForEach(launchpadFiltered) { app in
                            Button {
                                launch(app)
                                withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
                                    showLaunchpad = false
                                }
                            } label: {
                                VStack(spacing: 7) {
                                    launchpadImage(app)
                                    Text(app.displayLabel)
                                        .font(.caption)
                                        .foregroundStyle(.primary)
                                        .lineLimit(1)
                                }
                            }
                            .buttonStyle(.plain)
                            .task(id: app.package) {
                                await loadMetadata(for: app)
                            }
                        }
                    }
                    .padding(28)
                }
            }
            .padding(.top, 40)
        }
    }

    @ViewBuilder
    private func launchpadImage(_ app: AndroidApp) -> some View {
        if let image = icons[app.package] {
            Image(nsImage: image).resizable()
                .frame(width: 64, height: 64)
                .shadow(color: .black.opacity(0.25), radius: 5, y: 2)
        } else {
            RoundedRectangle(cornerRadius: 14)
                .fill(Color.accentColor.gradient)
                .frame(width: 64, height: 64)
                .overlay(Text(String(app.displayLabel.prefix(1)))
                    .font(.system(size: 24, weight: .bold, design: .rounded))
                    .foregroundStyle(.white))
                .shadow(color: .black.opacity(0.25), radius: 5, y: 2)
        }
    }

    // MARK: 동작

    private func launch(_ app: AndroidApp) {
        guard let device, device.state == .online else {
            appState.showError("기기가 온라인이 아닙니다.")
            return
        }
        appState.launchAppWindow(for: device, app: app)
        // 맥식 런치 바운스: 독 아이콘을 두 번 튀게 한다
        bouncingPackage = app.package
        Task {
            try? await Task.sleep(for: .milliseconds(700))
            bouncingPackage = nil
        }
    }

    private func load() async {
        if let loaded = try? await ADB.installedApps(serial: serial) {
            apps = loaded
        }
        loading = false
    }

    private func loadMetadata(for app: AndroidApp) async {
        guard icons[app.package] == nil else { return }
        let updated = await AppCatalog.loadMetadata(serial: serial, app: app)
        if let url = updated.iconURL, let image = NSImage(contentsOf: url) {
            icons[app.package] = image
        }
    }
}

// MARK: - 독 아이콘

/// 독 아이콘: 확대 배율 + 실행 중 점 + 런치 바운스를 입힌 버튼.
struct DockIconView<Content: View>: View {
    let scale: CGFloat
    let isRunning: Bool
    let bouncing: Bool
    let action: () -> Void
    @ViewBuilder let content: Content

    var body: some View {
        Button(action: action) {
            content
                .scaleEffect(scale)
                .offset(y: bouncing ? -16 : 0)
                .animation(bouncing ? .interpolatingSpring(stiffness: 380, damping: 12) : .default,
                           value: bouncing)
                .overlay(alignment: .bottom) {
                    if isRunning {
                        Circle().fill(.white)
                            .frame(width: 4, height: 4)
                            .offset(y: 8)
                    }
                }
        }
        .buttonStyle(.plain)
        .scaleEffect(y: bouncing ? 1.05 : 1, anchor: .bottom)  // 바운스시 아래 고정 느낌
    }
}

// MARK: - GeometryChange 헬퍼 (macOS 14 호환)

/// 독 아이콘의 전역 프레임 중심 X를 저장 — 거리 기반 확대 계산용.
/// (onGeometryChange는 macOS 15+라 PreferenceKey 방식으로 14를 지원한다.)
extension View {
    func onGeometryChangeStore(key: String, into centers: Binding<[String: CGFloat]>) -> some View {
        background(DockGeometryReader(key: key, centers: centers))
    }
}

struct DockGeometryReader: View {
    let key: String
    @Binding var centers: [String: CGFloat]

    var body: some View {
        GeometryReader { geometry in
            Color.clear
                .onChange(of: geometry.frame(in: .global).midX) { _, newCenter in
                    if centers[key] != newCenter {
                        centers[key] = newCenter
                    }
                }
                .onAppear {
                    centers[key] = geometry.frame(in: .global).midX
                }
        }
    }
}
