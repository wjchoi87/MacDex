import SwiftUI

/// 무선 연결 시트 — 3가지 경로(페어링 코드 / IP 직접 / mDNS 자동 발견).
struct PairSheetView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss

    enum Tab: String, CaseIterable, Identifiable {
        case code = "페어링 코드"
        case ip = "IP 직접 연결"
        case mdns = "자동 발견"

        var id: String { rawValue }
    }

    @State private var tab: Tab = .code
    @State private var pairHost = ""
    @State private var pairCode = ""
    @State private var connectHost = ""
    @State private var discovery = LanDiscovery()

    var body: some View {
        VStack(spacing: 0) {
            header

            Picker("연결 방식", selection: $tab) {
                ForEach(Tab.allCases) { t in
                    Text(t.rawValue).tag(t)
                }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 24)

            switch tab {
            case .code: pairCodeTab
            case .ip: directTab
            case .mdns: mdnsTab
            }

            footer
        }
        .frame(width: 480, height: 460)
        /* 진행 상태를 시트 안에서 보이게: 기존엔 메인 창 배너에만 뜨는데 시트가
           그 위를 덮어 페어링/연결 진행이 안 보였다. 같은 StatusBanner를 시트 하단에도 둔다. */
        .safeAreaInset(edge: .bottom) {
            if appState.busyMessage != nil || appState.toast != nil || appState.lastError != nil {
                /* 배너는 내부에서 Capsule + material 배경을 이미 그리므로, 여기서 사각 material을
                   한 번 더 깔면 캡슐 뒤에 네모난 판이 비쳐 보인다. 배경 없이 패딩만 준다. */
                StatusBanner()
                    .padding(.horizontal, 16)
                    .padding(.bottom, 4)
            }
        }
    }

    private var header: some View {
        VStack(spacing: 6) {
            Text("무선 기기 연결")
                .font(.title3.bold())
            Text("폰: 설정 → 개발자 옵션 → 무선 디버깅")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 20)
    }

    // MARK: 하단 액션(초보자용)

    /// 연결 복구 + 닫기 — 시트를 닫을 방법이 없다는 피드백 반영. Esc는 .cancelAction으로 연결.
    private var footer: some View {
        HStack {
            Button {
                appState.recoverConnections()
            } label: {
                Label("연결 복구", systemImage: "arrow.triangle.2.circlepath")
            }
            .help("adb 재시작, 연결했던 무선 기기 재접속, 주변 기기 재검색을 한 번에 실행합니다. 연결이 안 될 때 눌러보세요.")
            .disabled(isBusy)

            Spacer()

            Button("닫기") { dismiss() }
                .keyboardShortcut(.cancelAction)
        }
        .padding(.horizontal, 24)
        .padding(.bottom, 16)
    }

    // MARK: 페어링 코드

    private var pairCodeTab: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("무선 디버깅 화면에서 '기기 페어링'을 열면 나오는 주소와 6자리 코드를 입력하세요. 폰과 맥이 같은 Wi-Fi에 있어야 합니다.")
                .font(.callout)
                .foregroundStyle(.secondary)

            LabeledContent("페어링 주소") {
                TextField("예: 192.168.0.10:37001", text: $pairHost)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 220)
            }
            LabeledContent("코드") {
                TextField("6자리", text: $pairCode)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 120)
                    .onSubmit(pair)
            }

            HStack {
                Spacer()
                Button("페어링", action: pair)
                    .buttonStyle(.borderedProminent)
                    .disabled(pairHost.isEmpty || pairCode.isEmpty || isBusy)
            }

            Spacer()
            Label("페어링은 기기마다 한 번만 필요합니다. 이후에는 'IP 직접 연결'이나 '자동 발견'로 즉시 연결됩니다.",
                  systemImage: "info.circle")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 16)
    }

    // MARK: IP 직접

    private var directTab: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("무선 디버깅 화면의 IP 주소와 포트(예: 192.168.0.10:39523) 또는 이미 페어링된 기기의 5555 포트로 연결합니다.")
                .font(.callout)
                .foregroundStyle(.secondary)

            LabeledContent("주소") {
                TextField("예: 192.168.0.10:5555", text: $connectHost)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 220)
                    .onSubmit(connectDirect)
            }

            HStack {
                Spacer()
                Button("연결", action: connectDirect)
                    .buttonStyle(.borderedProminent)
                    .disabled(connectHost.isEmpty || isBusy)
            }
            Spacer()
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 16)
    }

    // MARK: mDNS

    /* 정책: 목록은 앱 자신의 Bonjour 탐색(LanDiscovery) 결과다 — adb 서버 mDNS는 서버를 누가
       띄웠는지에 따라 비어 있을 수 있어(실측) 쓰지 않는다. 같은 폰이 이미 다른 전송
       (USB·Tailscale·LAN)으로 붙어 있으면 '연결됨'으로 표시해 중복 연결을 만들지 않는다. */
    private var mdnsTab: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("같은 Wi-Fi에서 발견된 기기")
                    .font(.headline)
                if discovery.isBrowsing {
                    ProgressView().controlSize(.small)
                }
                Spacer()
                Button {
                    discovery.restart()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .help("다시 찾기")
            }

            if discovery.services.isEmpty {
                VStack(spacing: 8) {
                    // 권한 거부가 확인되면 이것이 1순위 원인 — 폰 안내보다 먼저 보여준다(실측 사례)
                    if discovery.permission == .denied {
                        Image(systemName: "network.badge.shield.half.filled")
                            .font(.largeTitle)
                            .foregroundStyle(.orange)
                        Text("MacDroid의 로컬 네트워크 접근이 차단되어 있습니다.\n같은 Wi-Fi의 기기를 찾을 수 없습니다.")
                            .multilineTextAlignment(.center)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                        Button {
                            LocalNetworkPermission.openSystemSettings()
                        } label: {
                            Label("시스템 설정에서 허용하기", systemImage: "gear")
                        }
                        .buttonStyle(.borderedProminent)
                        .padding(.top, 4)
                        Button {
                            discovery.restart()
                        } label: {
                            Text("권한을 허용한 뒤 다시 검색")
                        }
                    } else {
                        Image(systemName: "wifi.router")
                            .font(.largeTitle)
                            .foregroundStyle(.tertiary)
                        Text("찾는 중… 기기가 보이지 않으면\n폰에서 무선 디버깅을 켜고 맥과 같은 Wi-Fi에 연결하세요.")
                            .multilineTextAlignment(.center)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                        // mDNS는 같은 LAN에서만 동작 — VPN으로 붙은 기기가 있으면 그 사실을 안내(실측 사례)
                        if vpnConnectedDeviceExists {
                            Text("지금 VPN(Tailscale 등)으로 연결된 기기가 있습니다.\n자동 발견은 같은 와이파이에서만 동작하니, 'IP 직접 연결' 탭을 사용하세요.")
                                .multilineTextAlignment(.center)
                                .font(.caption)
                                .foregroundStyle(.orange)
                                .padding(.top, 4)
                        }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(discovery.services) { service in
                    HStack {
                        Image(systemName: service.kind == .pairing
                              ? "key.radiowaves.forward" : "iphone.radiowaves.left.and.right")
                            .foregroundStyle(.tint)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(serviceTitle(service))
                            Text(service.address)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .monospaced()
                        }
                        Spacer()
                        switch service.kind {
                        case .connect:
                            if isAlreadyConnected(service) {
                                Label("연결됨", systemImage: "checkmark.circle.fill")
                                    .foregroundStyle(.green)
                                    .font(.callout)
                            } else {
                                Button("연결") {
                                    appState.connect(host: service.address)
                                }
                                .disabled(isBusy)
                            }
                        case .pairing:
                            // 페어링 포트는 창을 열 때마다 바뀐다 — 주소를 채워 코드 탭으로 보낸다
                            Button("코드 입력") {
                                pairHost = service.address
                                tab = .code
                            }
                        }
                    }
                }
                .listStyle(.inset)
            }
        }
        .padding(24)
        .onAppear { discovery.start() }
        .onDisappear { discovery.stop() }
    }

    private func serviceTitle(_ service: LanDiscovery.Service) -> String {
        let name = matchingDevice(service)?.displayModel ?? service.deviceSerial ?? service.instance
        return service.kind == .pairing ? "\(name) · 페어링 대기" : "\(name) · 무선 디버깅"
    }

    /// 같은 폰이 이미 online인지(시리얼·주소·mDNS 자동연결 이름 기준).
    private func matchingDevice(_ service: LanDiscovery.Service) -> Device? {
        appState.devices.first { device in
            device.state == .online && (
                device.serial == service.address
                || device.serial.hasPrefix(service.instance)
                || (service.deviceSerial != nil && device.serialNo == service.deviceSerial)
            )
        }
    }

    private func isAlreadyConnected(_ service: LanDiscovery.Service) -> Bool {
        matchingDevice(service) != nil
    }

    /// 진행 중(페어링/연결/전환)이면 액션 버튼 잠금 — 중복 실행 방지.
    private var isBusy: Bool {
        appState.busyMessage != nil
    }

    /// 현재 CGNAT(VPN) 대역으로 붙어 있는 무선 기기가 있는지 — 자동발견 불가 안내용.
    private var vpnConnectedDeviceExists: Bool {
        appState.devices.contains { $0.isVPNConnected }
    }

    private func pair() {
        appState.pair(host: pairHost, code: pairCode)
    }

    private func connectDirect() {
        appState.connect(host: connectHost)
    }
}
