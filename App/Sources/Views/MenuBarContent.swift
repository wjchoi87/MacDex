import SwiftUI
import AppKit

/// 메뉴바 익스트라 — 기기 빠른 미러링 + 앱 열기.
struct MenuBarContent: View {
    @Environment(AppState.self) private var appState
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        if appState.devices.isEmpty {
            Text("연결된 기기 없음")
        } else {
            ForEach(appState.devices.filter { $0.state == .online }) { device in
                Button {
                    openWindow(id: "main")
                    NSApp.activate(ignoringOtherApps: true)
                    appState.launchMirror(for: device)
                } label: {
                    Label("\(device.displayModel) 미러링", systemImage: "rectangle.on.rectangle")
                }
            }
        }

        Divider()
        Button {
            openWindow(id: "main")
            NSApp.activate(ignoringOtherApps: true)
        } label: {
            Label("MacDroid 열기", systemImage: "macwindow")
        }
        SettingsLink {
            Label("설정…", systemImage: "gearshape")
        }
        Divider()
        Button("MacDroid 종료") {
            NSApp.terminate(nil)
        }
        .keyboardShortcut("q")
    }
}
