import SwiftUI
import AppKit

/// DeX 앱 런처 — 기기의 앱을 그리드로 보여주고, 더블클릭으로 가상 디스플레이 창에서 실행.
/// 정책: 앱 라벨/아이콘은 보이는 타일만 지연 로딩(aapt2 + 캐시). 대형 APK는 모노그램 타일 유지.
struct LauncherView: View {
    @Environment(AppState.self) private var appState

    let serial: String

    @State private var apps: [AndroidApp] = []
    @State private var icons: [String: NSImage] = [:]
    @State private var loading = true
    @State private var loadError: String?
    @State private var searchText = ""
    @State private var showSystemApps = false
    @State private var loadTask: Task<Void, Never>?
    @State private var duplicateApp: AndroidApp?

    private var device: Device? {
        appState.device(for: serial)
    }

    private var filteredApps: [AndroidApp] {
        guard !searchText.isEmpty else { return apps }
        let query = searchText.lowercased()
        return apps.filter {
            $0.package.lowercased().contains(query)
                || $0.displayLabel.lowercased().contains(query)
        }
    }

    var body: some View {
        Group {
            if loading {
                ProgressView("앱 목록 불러오는 중…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let loadError {
                ContentUnavailableView {
                    Label("앱 목록을 가져오지 못했습니다", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(loadError)
                } actions: {
                    Button("다시 시도") { load() }
                }
            } else {
                appGrid
            }
        }
        .navigationTitle("앱 런처 · \(device?.displayModel ?? serial)")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Toggle(isOn: $showSystemApps) {
                    Label("시스템 앱 포함", systemImage: "gearshape.2")
                }
                .toggleStyle(.checkbox)
                // 툴바 첫 아이템이라 왼쪽에 붙음 — 좌우 여백 확보
                .padding(.horizontal, 8)
                .help("시스템 앱도 표시")
            }
            ToolbarItem(placement: .primaryAction) {
                Button {
                    load()
                } label: {
                    Label("새로고침", systemImage: "arrow.clockwise")
                }
            }
        }
        .searchable(text: $searchText, placement: .toolbar, prompt: "앱 검색")
        .onChange(of: showSystemApps) {
            load()
        }
        .task {
            load()
        }
        .onDisappear {
            loadTask?.cancel()
        }
        .alert(
            "\(duplicateApp?.displayLabel ?? "") — 이미 실행 중",
            isPresented: Binding(
                get: { duplicateApp != nil },
                set: { if !$0 { duplicateApp = nil } }
            ),
            presenting: duplicateApp
        ) { app in
            Button("새 창으로 실행") {
                if let device {
                    appState.launchAppWindow(for: device, app: app, forceNewInstance: true)
                }
            }
            Button("기존 창 닫고 새로 실행", role: .destructive) {
                if let device {
                    appState.relaunchAppWindow(for: device, app: app)
                }
            }
            Button("취소", role: .cancel) {}
        } message: { _ in
            Text("같은 앱을 별도의 새 창으로 또 띄울 수 있습니다. 기존 창을 그대로 이어서 쓰려면 취소하고, 기존 창을 닫은 뒤 다시 실행하세요.")
        }
    }

    private var appGrid: some View {
        ScrollView {
            if filteredApps.isEmpty {
                Text("검색 결과 없음")
                    .foregroundStyle(.secondary)
                    .padding(.top, 60)
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 108), spacing: 16)], spacing: 18) {
                    ForEach(filteredApps) { app in
                        AppTile(
                            app: app,
                            icon: icons[app.package],
                            isRunning: appState.sessions.contains {
                                $0.deviceSerial == serial && $0.id.hasSuffix("|app|\(app.package)")
                            }
                        )
                        .onTapGesture(count: 2) {
                            launchOrAsk(app)
                        }
                        .task(id: app.package) {
                            await loadMetadata(for: app)
                        }
                    }
                }
                .padding(20)
            }
        }
    }

    private func launch(_ app: AndroidApp) {
        guard let device, device.state == .online else {
            appState.showError("기기가 온라인이 아닙니다.")
            return
        }
        appState.launchAppWindow(for: device, app: app)
    }

    /* 변경 전 정책: 이미 실행 중인 앱을 더블클릭하면 조용히 무시했다.
       변경 후 정책: 사용자에게 묻는다 — (1) 별도 새 창으로 또 띄우기(새 인스턴스),
         (2) 기존 창을 닫고 새로 실행, (3) 취소 + "기존 창을 닫은 뒤 다시 실행" 안내.
       이유: Android는 기본적으로 앱 task를 재사용하므로 의도치 않은 이중 실행과
         사용자 혼란(아무 반응 없음)을 같이 해소하기 위함.
       영향 범위: DeX 런처의 동일 앱 재실행 경로만. 새 인스턴스는 scrcpy '+' 프리픽스로 강제. */
    private func launchOrAsk(_ app: AndroidApp) {
        guard let device, device.state == .online else {
            appState.showError("기기가 온라인이 아닙니다.")
            return
        }
        let alreadyRunning = appState.sessions.contains {
            $0.deviceSerial == device.serial && $0.id.hasSuffix("|app|\(app.package)")
        }
        if alreadyRunning {
            duplicateApp = app
        } else {
            appState.launchAppWindow(for: device, app: app)
        }
    }

    private func load() {
        loadTask?.cancel()
        loading = true
        loadError = nil
        loadTask = Task {
            do {
                let loaded = try await ADB.installedApps(serial: serial, includeSystem: showSystemApps)
                if Task.isCancelled { return }
                apps = loaded
                loading = false
            } catch {
                if Task.isCancelled { return }
                loadError = error.localizedDescription
                loading = false
            }
        }
    }

    /// 보이는 타일의 메타데이터만 로드해 원본 배열과 아이콘 캐시를 갱신.
    private func loadMetadata(for app: AndroidApp) async {
        guard app.iconURL == nil, app.label == nil, icons[app.package] == nil else { return }
        let updated = await AppCatalog.loadMetadata(serial: serial, app: app)
        guard !Task.isCancelled,
              let index = apps.firstIndex(where: { $0.package == app.package }) else { return }
        if updated.iconURL != nil || updated.label != nil {
            apps[index] = updated
            if let url = updated.iconURL, let image = NSImage(contentsOf: url) {
                icons[app.package] = image
            }
        }
    }
}

// MARK: - 앱 타일

struct AppTile: View {
    let app: AndroidApp
    let icon: NSImage?
    let isRunning: Bool

    private static let palette: [Color] = [
        .blue, .purple, .teal, .indigo, .mint, .orange, .pink, .cyan
    ]

    private var monogramColor: Color {
        Self.palette[app.monogramColorIndex % Self.palette.count]
    }

    var body: some View {
        VStack(spacing: 8) {
            ZStack(alignment: .topTrailing) {
                iconView
                    .frame(width: 64, height: 64)
                if isRunning {
                    Circle()
                        .fill(Color.green)
                        .frame(width: 10, height: 10)
                        .overlay(Circle().stroke(.white, lineWidth: 2))
                        .offset(x: 2, y: -2)
                }
            }
            Text(app.displayLabel)
                .font(.caption)
                .lineLimit(2)
                .multilineTextAlignment(.center)
                .help("\(app.displayLabel)\n\(app.package)\n더블클릭: DeX 창에서 실행")
        }
        .padding(8)
        .contentShape(.rect)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(.quinary.opacity(0.4))
        )
    }

    @ViewBuilder
    private var iconView: some View {
        if let icon {
            Image(nsImage: icon)
                .resizable()
                .interpolation(.high)
        } else {
            // 모노그램 폴백 타일(아이콘 로딩 전/대형 APK)
            ZStack {
                RoundedRectangle(cornerRadius: 14)
                    .fill(monogramColor.gradient)
                Text(String(app.displayLabel.prefix(1)))
                    .font(.system(size: 26, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
            }
        }
    }
}
