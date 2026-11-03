import SwiftUI
import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationWillFinishLaunching(_ notification: Notification) {
        // 데스크톱 도구 성격: 윈도우가 닫혀도 앱 유지(메뉴바에서 재접근)
        NSApp.setActivationPolicy(.regular)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationWillTerminate(_ notification: Notification) {
        AppState.shared.shutdownAll()
    }
}

@main
struct MacDroidApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var appState = AppState.shared

    var body: some Scene {
        Window("MacDroid", id: "main") {
            MainView()
                .environment(appState)
        }
        .defaultSize(width: 1080, height: 720)
        .commands {
            MacDroidCommands()
        }

        // DeX 앱 런처 — 기기 시리얼을 값으로 갖는 윈도우(기기별 다중 창)
        WindowGroup(id: "launcher", for: String.self) { $serial in
            if let serial {
                LauncherView(serial: serial)
                    .environment(appState)
            } else {
                ContentUnavailableView("기기 없음", systemImage: "iphone.slash",
                                       description: Text("연결된 기기를 선택하세요."))
            }
        }
        .defaultSize(width: 1000, height: 660)

        Settings {
            SettingsView()
                .environment(appState)
        }

        MenuBarExtra("MacDroid", systemImage: "menubar.rectangle.on.rectangle") {
            MenuBarContent()
                .environment(appState)
        }
    }
}

struct MacDroidCommands: Commands {
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        SidebarCommands()
        CommandGroup(after: .appInfo) {
            SettingsLink {
                Text("설정…")
            }
            .keyboardShortcut(",", modifiers: .command)
        }
        CommandGroup(after: .newItem) {
            Button("기기 무선 연결…") {
                NotificationCenter.default.post(name: .macdroidOpenPair, object: nil)
            }
            .keyboardShortcut("k", modifiers: .command)
        }
    }
}

extension Notification.Name {
    static let macdroidOpenPair = Notification.Name("macdroidOpenPair")
}
