import SwiftUI
import AppKit

/// DeX 앱 런처 — 폰 앱 서랍과 같은 목록(실제 이름·아이콘)을 보여주고, 더블클릭하면 데스크톱 안의 창으로 연다.
/* 변경 전 정책: 서드파티 앱만, 라벨/아이콘은 타일마다 APK를 받아 aapt2로(느리고 대부분 모노그램). 같은 앱 재실행은
     확인 다이얼로그. 변경 후 정책: 기기 인덱서(AppCatalog.loadIndex)로 런처 목록 전체를 실제 라벨·아이콘과 함께 받는다
     (실패 시 기존 방식 폴백). 이미 열린 앱을 다시 열면 그 창이 앞으로 온다(데스크톱 동작) — 새 창/다시 시작은 우클릭 메뉴.
     Esc·⌘W로 닫힌다. 영향 범위: 앱 런처 창. */
struct LauncherView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismissWindow) private var dismissWindow
    @Environment(\.openWindow) private var openWindow

    let serial: String

    @State private var apps: [AndroidApp] = []
    @State private var icons: [String: NSImage] = [:]
    @State private var loading = true
    @State private var loadError: String?
    @State private var searchText = ""
    @State private var loadTask: Task<Void, Never>?

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
                Button {
                    openWindow(id: "desktop", value: serial)
                } label: {
                    Label("데스크톱 열기", systemImage: "dock.rectangle")
                }
                .help("MacDroid 데스크톱 창 열기 — 앱은 그 안에서 창으로 열립니다")
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
        .onExitCommand { dismissWindow() }
        .task {
            load()
        }
        .onDisappear {
            loadTask?.cancel()
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
                            isRunning: appState.desktops[serial]?.isRunning(app.package) ?? false
                        )
                        .onTapGesture(count: 2) {
                            launch(app)
                        }
                        .contextMenu {
                            Button("열기") { launch(app) }
                            Button("새 창으로 열기") { launch(app, newInstance: true) }
                            Button("다시 시작") {
                                if let device {
                                    appState.relaunchAppWindow(for: device, app: app)
                                    openWindow(id: "desktop", value: serial)
                                }
                            }
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

    private func launch(_ app: AndroidApp, newInstance: Bool = false) {
        guard let device, device.state == .online else {
            appState.showError("기기가 온라인이 아닙니다.")
            return
        }
        appState.launchAppWindow(for: device, app: app, forceNewInstance: newInstance)
        openWindow(id: "desktop", value: serial)
    }

    private func load() {
        loadTask?.cancel()
        loading = true
        loadError = nil
        loadTask = Task {
            do {
                let loaded: [AndroidApp]
                if let indexed = await AppCatalog.loadIndex(serial: serial) {
                    loaded = indexed
                } else {
                    loaded = try await ADB.installedApps(serial: serial)
                }
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
        guard icons[app.package] == nil else { return }
        // 인덱서가 이미 아이콘을 받아 둔 앱 — 파일만 읽는다
        if let url = app.iconURL {
            if let image = NSImage(contentsOf: url) { icons[app.package] = image }
            return
        }
        guard app.label == nil else { return }
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
                .help("\(app.displayLabel)\n\(app.package)\n더블클릭: 데스크톱에서 열기 · 우클릭: 새 창/다시 시작")
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
