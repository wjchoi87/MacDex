import SwiftUI
import AppKit

/// MacDroid DeX 독 — 우리만의 DeX 데스크톱 셸(맥 쪽 패널).
/* 정책: DeX 모니터(가상 디스플레이 창)는 "모니터" 역할만 하고, 데스크톱 셸은 이 독이
   담당한다 — 앱 실행/전환, 열린 앱, 뒤로 키. 삼성 여부와 무관하게 동작한다. */
struct DexDockView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss

    let serial: String

    @State private var apps: [AndroidApp] = []
    @State private var icons: [String: NSImage] = [:]
    @State private var searchText = ""
    @State private var loading = true

    private var device: Device? { appState.device(for: serial) }
    private var displayId: Int? { appState.dexDisplays[serial] }
    private var opened: [AndroidApp] { appState.dexOpenedApps[serial] ?? [] }

    private var filtered: [AndroidApp] {
        guard !searchText.isEmpty else { return apps }
        let query = searchText.lowercased()
        return apps.filter {
            $0.package.lowercased().contains(query) || $0.displayLabel.lowercased().contains(query)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            header

            if loading {
                Spacer()
                ProgressView("앱 목록 불러오는 중…")
                Spacer()
            } else {
                if !opened.isEmpty {
                    openedSection
                }
                appList
            }

            footer
        }
        .frame(minWidth: 320, idealWidth: 340, minHeight: 460, idealHeight: 580)
        .task {
            await load()
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Image(systemName: "dock.rectangle")
                    .foregroundStyle(Color.accentColor)
                Text("DeX 독 · \(device?.displayModel ?? serial)")
                    .font(.headline)
                Spacer()
            }
            Text(displayId.map { "모니터 디스플레이 #\($0) — 앱을 누르면 DeX 창에서 열립니다" }
                 ?? "DeX 모니터 대기 중…")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(14)
        .background(.quinary.opacity(0.4))
    }

    private var openedSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("열린 앱")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 14)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(opened.reversed()) { app in
                        Button {
                            if let device { appState.dexLaunchApp(on: device, app: app) }
                        } label: {
                            HStack(spacing: 6) {
                                dockIcon(app, size: 18)
                                Text(app.displayLabel)
                                    .font(.caption)
                                    .lineLimit(1)
                            }
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                        }
                        .buttonStyle(.bordered)
                        .help("\(app.package) — 눌러서 전환")
                    }
                }
                .padding(.horizontal, 14)
            }
        }
        .padding(.vertical, 8)
    }

    private var appList: some View {
        List(filtered) { app in
            Button {
                if let device { appState.dexLaunchApp(on: device, app: app) }
            } label: {
                HStack(spacing: 10) {
                    dockIcon(app, size: 28)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(app.displayLabel)
                            .foregroundStyle(.primary)
                        Text(app.package)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Image(systemName: "arrow.up.forward.app")
                        .foregroundStyle(.tertiary)
                }
            }
            .buttonStyle(.plain)
            .task(id: app.package) {
                await loadMetadata(for: app)
            }
        }
        .listStyle(.plain)
        .searchable(text: $searchText, placement: .toolbar, prompt: "앱 검색")
    }

    private var footer: some View {
        HStack {
            Button {
                if let device { appState.dexBack(on: device) }
            } label: {
                Label("뒤로", systemImage: "chevron.backward")
            }
            .disabled(displayId == nil)

            Spacer()

            Button(role: .destructive) {
                if let device { appState.stopDexDesktop(for: device) }
                dismiss()
            } label: {
                Label("DeX 종료", systemImage: "xmark.rectangle")
            }
            .disabled(displayId == nil)
        }
        .padding(14)
        .background(.quinary.opacity(0.4))
    }

    // MARK: 헬퍼

    @ViewBuilder
    private func dockIcon(_ app: AndroidApp, size: CGFloat) -> some View {
        if let image = icons[app.package] {
            Image(nsImage: image)
                .resizable()
                .frame(width: size, height: size)
        } else {
            Image(systemName: "app")
                .foregroundStyle(.tint)
                .frame(width: size, height: size)
        }
    }

    private func load() async {
        guard let device, device.state == .online else {
            loading = false
            return
        }
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
