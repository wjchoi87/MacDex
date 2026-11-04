import SwiftUI

struct MainView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.openWindow) private var openWindow
    @State private var selectedSerial: String?
    // 정책: 시트는 한 브랜치에 하나만 — 여러 sheet 수정자를 붙이면 macOS에서
    //   해제 동작이 무시되는 SwiftUI 함정이 있어 item 기반 단일 시트로 통합했다.
    enum ActiveSheet: Identifiable {
        case onboarding, pair
        var id: Int { hashValue }
    }
    @State private var activeSheet: ActiveSheet?
    @State private var showOnboarding = !UserDefaults.standard.bool(forKey: "MacDroid.onboardingDone")

    private var selectedDevice: Device? {
        guard let selectedSerial else { return nil }
        return appState.devices.first { $0.serial == selectedSerial }
    }

    var body: some View {
        NavigationSplitView {
            DeviceSidebar(selection: $selectedSerial) {
                activeSheet = .pair
            }
            .navigationSplitViewColumnWidth(min: 220, ideal: 250, max: 320)
        } detail: {
            Group {
                if let device = selectedDevice {
                    DeviceDetailView(device: device)
                } else {
                    EmptyStateView {
                        activeSheet = .onboarding
                    } onRecover: {
                        appState.recoverConnections()
                    } onPair: {
                        activeSheet = .pair
                    }
                }
            }
            // 연결 관련 알림은 오른쪽(상세) 패널의 가운데 아래에(변경 전: 창 전체 가운데 아래 — 사이드바에 걸쳐 보였다)
            .overlay(alignment: .bottom) {
                StatusBanner()
            }
        }
        .navigationTitle("MacDroid")
        .sheet(item: $activeSheet) { sheet in
            switch sheet {
            case .onboarding:
                OnboardingView()
            case .pair:
                PairSheetView()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .macdroidOpenPair)) { _ in
            activeSheet = .pair
        }
        .task {
            appState.start()
            // 첫 실행이면 온보딩 표시
            if showOnboarding { activeSheet = .onboarding }
        }
        // 기기가 잡히면: 아직 선택 없으면 첫 기기 자동 선택 + 온보딩 자동 완료
        /* 변경 전: online 기기만 자동 선택 → USB '승인 필요' 기기는 빈 화면에 가려 "폰에서 허용"
           안내가 안 보였다. 변경 후: online 우선, 없으면 승인 대기 기기도 선택해 안내 카드를 띄운다. */
        .onChange(of: appState.devices) { _, devices in
            guard selectedSerial == nil || selectedDevice == nil else { return }
            if let pick = devices.first(where: { $0.state == .online })
                ?? devices.first(where: { $0.state == .unauthorized }) {
                selectedSerial = pick.serial
            }
        }
        .onChange(of: appState.devices.contains { $0.state == .online }) { _, connected in
            if connected, activeSheet == .onboarding {
                Task {
                    try? await Task.sleep(for: .seconds(1))
                    if activeSheet == .onboarding { activeSheet = nil }
                }
            }
        }
    }
}

// MARK: - 사이드바

struct DeviceSidebar: View {
    @Environment(AppState.self) private var appState
    @Binding var selection: String?
    var onPair: () -> Void

    var body: some View {
        List(selection: $selection) {
            if appState.devices.isEmpty {
                Label("연결된 기기 없음", systemImage: "iphone.slash")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(appState.devices) { device in
                    DeviceRow(device: device)
                        .tag(device.serial)
                }
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom) {
            Button {
                onPair()
            } label: {
                Label("무선 기기 연결", systemImage: "plus")
                    .frame(maxWidth: .infinity)
            }
            .controlSize(.large)
            .buttonStyle(.borderedProminent)
            .padding()
        }
    }
}

struct DeviceRow: View {
    let device: Device

    private var batteryText: String {
        guard let level = device.batteryLevel else { return "" }
        return "\(level)%"
    }

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: device.isUSB ? "cable.connector" : "wifi")
                .font(.title3)
                .foregroundStyle(device.state == .online ? Color.accentColor : .secondary)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(device.displayModel)
                    .lineLimit(1)
                Text(device.stateBadge + (batteryText.isEmpty ? "" : " · \(batteryText)"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 2)
    }
}

// MARK: - 빈 상태

struct EmptyStateView: View {
    var onGuide: () -> Void
    var onRecover: () -> Void
    var onPair: () -> Void

    @Environment(AppState.self) private var appState

    var body: some View {
        VStack(spacing: 24) {
            Image(systemName: "rectangle.on.rectangle")
                .font(.system(size: 56, weight: .light))
                .foregroundStyle(.tertiary)

            VStack(spacing: 8) {
                Text("기기를 연결하세요")
                    .font(.title2.bold())
                Text("USB 케이블로 연결하거나, 무선 디버깅으로 페어링하면\n폰 화면과 앱을 맥 윈도우에서 쓸 수 있습니다.")
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            // 로컬 네트워크 차단이 확인되면 무선은 절대 안 된다 — 1순위로 바로 해결 버튼을 준다
            if appState.discovery.permission == .denied {
                VStack(spacing: 8) {
                    Label("MacDroid의 로컬 네트워크 접근이 꺼져 있어 같은 Wi-Fi의 폰을 찾을 수 없습니다.",
                          systemImage: "network.badge.shield.half.filled")
                        .foregroundStyle(.orange)
                    HStack {
                        Button("시스템 설정에서 허용하기") {
                            LocalNetworkPermission.openSystemSettings()
                        }
                        .buttonStyle(.borderedProminent)
                        Button("허용했어요, 다시 찾기") {
                            appState.restartDiscovery()
                        }
                    }
                }
                .padding(12)
                .background(.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
            } else if let found = appState.discovery.services.first(where: { $0.kind == .connect }) {
                Label("같은 Wi-Fi에서 \(found.displayName) 발견", systemImage: "wifi")
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 12) {
                Button {
                    onGuide()
                } label: {
                    Label("연결 가이드", systemImage: "questionmark.circle")
                }

                // 연결했던 기기가 갑자기 안 보일 때 — adb 리셋 + 무선 재접속 원클릭
                Button {
                    onRecover()
                } label: {
                    Label("연결 복구", systemImage: "arrow.triangle.2.circlepath")
                }
                .disabled(appState.busyMessage != nil)

                Button {
                    onPair()
                } label: {
                    Label("무선으로 연결", systemImage: "wifi")
                        .padding(.horizontal, 6)
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - 상태 배너(토스트/진행/오류)

struct StatusBanner: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        VStack(spacing: 8) {
            if let busy = appState.busyMessage {
                banner(icon: "hourglass", text: busy, color: .secondary)
            }
            if let toast = appState.toast {
                banner(icon: "checkmark.circle.fill", text: toast, color: .green)
                    .task {
                        try? await Task.sleep(for: .seconds(3.5))
                        appState.clearToast()
                    }
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
            if let error = appState.lastError {
                banner(icon: "exclamationmark.triangle.fill", text: error, color: .orange, dismissible: true)
            }
        }
        .padding(.bottom, 16)
        .animation(.spring(duration: 0.3), value: appState.toast)
        .animation(.spring(duration: 0.3), value: appState.lastError)
    }

    private func banner(icon: String, text: String, color: Color, dismissible: Bool = false) -> some View {
        HStack(spacing: 10) {
            if icon == "hourglass" {
                ProgressView().controlSize(.small)
            } else {
                Image(systemName: icon).foregroundStyle(color)
            }
            Text(text)
                .font(.callout)
                .lineLimit(3)
            if dismissible {
                Button {
                    appState.lastError = nil
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.ultraThinMaterial, in: Capsule())
        .shadow(color: .black.opacity(0.15), radius: 8, y: 2)
        .padding(.horizontal)
    }
}
