import SwiftUI

struct DeviceDetailView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.openWindow) private var openWindow

    let device: Device

    @State private var showFileImporter = false

    private var deviceSessions: [ScrcpySession] {
        appState.sessions.filter { $0.deviceSerial == device.serial }
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                headerCard

                if device.state == .unauthorized {
                    unauthorizedCard
                }

                actionBar
                quickToggles
                if !deviceSessions.isEmpty {
                    sessionsCard
                }
                infoCard
            }
            .padding(24)
            .frame(maxWidth: .infinity)
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    // MARK: 헤더

    private var headerCard: some View {
        HStack(spacing: 20) {
            ZStack {
                RoundedRectangle(cornerRadius: 18)
                    .fill(
                        LinearGradient(colors: [.accentColor.opacity(0.7), .accentColor.opacity(0.3)],
                                       startPoint: .topLeading, endPoint: .bottomTrailing)
                    )
                    .frame(width: 72, height: 72)
                Image(systemName: "iphone.gen3")
                    .font(.system(size: 34, weight: .medium))
                    .foregroundStyle(.white)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text(device.displayModel)
                    .font(.title2.bold())
                HStack(spacing: 8) {
                    Label(device.stateBadge, systemImage: device.isUSB ? "cable.connector" : "wifi")
                    if let version = device.androidVersion {
                        Label("Android \(version)", systemImage: "gearshape")
                    }
                    if let level = device.batteryLevel {
                        Label("\(level)%", systemImage: batterySymbol)
                    }
                }
                .font(.caption)
                .padding(.vertical, 3)
                .padding(.horizontal, 8)
                .background(.quaternary, in: Capsule())
            }

            Spacer()

            VStack(spacing: 6) {
                Button {
                    appState.refreshDevice(device)
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .help("기기 정보 새로고침")
            }
        }
        .padding(20)
        .background(.background, in: RoundedRectangle(cornerRadius: 16))
        .shadow(color: .black.opacity(0.04), radius: 4, y: 1)
    }

    private var batterySymbol: String {
        guard let charging = device.isCharging, charging else { return "battery.100" }
        return "battery.100.bolt"
    }

    // MARK: 승인 필요

    private var unauthorizedCard: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "hand.raised.fill")
                .font(.title3)
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 4) {
                Text("폰에서 USB 디버깅을 허용해주세요")
                    .font(.headline)
                Text("이 컴퓨터의 디버깅을 허용하시겠습니까? 알림이 뜨면 '허용'을 누르세요. 알림이 안 보이면 USB 케이블을 다시 연결해보세요.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
    }

    // MARK: 액션

    private var actionBar: some View {
        Grid(alignment: .center, horizontalSpacing: 12, verticalSpacing: 12) {
            GridRow {
                ActionButton(title: "화면 미러링", icon: "rectangle.on.rectangle",
                             prominent: device.state == .online) {
                    appState.launchMirror(for: device)
                }
                ActionButton(title: "DeX 앱 런처", icon: "square.grid.2x2",
                             prominent: device.state == .online) {
                    openWindow(id: "launcher", value: device.serial)
                }
            }
            GridRow {
                if device.isUSB {
                    ActionButton(title: "무선으로 전환", icon: "wifi") {
                        appState.enableWireless(for: device)
                    }
                }
                ActionButton(title: "파일 보내기", icon: "tray.and.arrow.up") {
                    showFileImporter = true
                }
            }
        }
        .disabled(device.state != .online)
        .opacity(device.state == .online ? 1 : 0.4)
        .fileImporter(isPresented: $showFileImporter, allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
            if case .success(let urls) = result {
                appState.pushFiles(urls, to: device)
            }
        }
    }

    private var quickToggles: some View {
        @Bindable var state = appState
        return HStack(spacing: 16) {
            Toggle("미러링 중 화면 끄기", isOn: Binding(
                get: { state.settings.turnScreenOff },
                set: { state.settings.turnScreenOff = $0 }
            ))
            Toggle("깨어있기 유지", isOn: Binding(
                get: { state.settings.stayAwake },
                set: { state.settings.stayAwake = $0 }
            ))
            Spacer()
        }
        .padding(16)
        .background(.background, in: RoundedRectangle(cornerRadius: 12))
    }

    // MARK: 실행 중 세션

    private var sessionsCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("실행 중인 창", systemImage: "sparkles")
                .font(.headline)
            ForEach(deviceSessions) { session in
                HStack {
                    Image(systemName: session.mode == .mirror ? "rectangle.on.rectangle" : "app")
                        .foregroundStyle(.tint)
                    Text(session.title)
                        .lineLimit(1)
                    Spacer()
                    Button("닫기") {
                        appState.stopSession(session)
                    }
                }
                .padding(.vertical, 6)
                .padding(.horizontal, 12)
                .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background, in: RoundedRectangle(cornerRadius: 12))
    }

    // MARK: 기기 정보

    private var infoCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            LabeledRow(label: "제조사", value: [device.manufacturer, device.brand]
                .compactMap { $0 }.removingDuplicates().joined(separator: " · "))
            LabeledRow(label: "Android", value: device.androidVersion.map { "\($0) (API \(device.sdkInt.map(String.init) ?? "?"))" })
            LabeledRow(label: "화면", value: device.screenSize)
            LabeledRow(label: "시리얼", value: device.serial, monospaced: true)
            LabeledRow(label: "연결", value: device.isUSB ? "USB" : "Wi-Fi (adb over TCP)")
        }
        .padding(16)
        .background(.background, in: RoundedRectangle(cornerRadius: 12))
    }
}

// MARK: - 구성요소

struct ActionButton: View {
    let title: String
    let icon: String
    var prominent: Bool = false
    let action: () -> Void

    private var coreButton: some View {
        Button(action: action) {
            VStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.title2)
                Text(title)
                    .font(.callout.weight(.medium))
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 16)
        }
        .controlSize(.large)
    }

    var body: some View {
        if prominent {
            coreButton.buttonStyle(.borderedProminent)
        } else {
            coreButton.buttonStyle(.bordered)
        }
    }
}

struct LabeledRow: View {
    let label: String
    let value: String?
    var monospaced = false

    var body: some View {
        HStack {
            Text(label)
                .foregroundStyle(.secondary)
                .frame(width: 90, alignment: .leading)
            if let value {
                Text(value)
                    .font(monospaced ? .system(.body, design: .monospaced) : .body)
                    .textSelection(.enabled)
            } else {
                Text("-").foregroundStyle(.tertiary)
            }
            Spacer()
        }
        .padding(.vertical, 5)
    }
}

extension Array where Element == String {
    func removingDuplicates() -> [String] {
        var seen: Set<String> = []
        return filter { seen.insert($0).inserted }
    }
}
