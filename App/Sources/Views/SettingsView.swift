import SwiftUI

/// 설정 — 품질 프리셋/상세 옵션/DeX 가상 디스플레이/캐시.
/// 정책: 프리셋 선택은 video 값을 덮어쓴다. 개별 값을 직접 수정하면 프리셋과 달라진
///   "사용자 지정" 상태가 된다(프리셋 재선택 시 되돌아옴).
struct SettingsView: View {
    @Environment(AppState.self) private var appState

    @State private var cacheSize: String = "계산 중…"

    var body: some View {
        @Bindable var state = appState
        TabView {
            Form {
                Section("화면 품질") {
                    Picker("프리셋", selection: Binding(
                        get: { state.settings.preset },
                        set: { state.settings.preset = $0; state.settings.video = $0.values }
                    )) {
                        ForEach(QualityPreset.allCases) { preset in
                            Text(preset.title).tag(preset)
                        }
                    }
                    if let current = QualityPreset.allCases.first(where: { $0.values == state.settings.video }) {
                        Text(current.subtitle)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        Text("사용자 지정 — 프리셋과 다른 값이 설정되어 있습니다")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }

                    Picker("비디오 코덱", selection: Binding(
                        get: { state.settings.video.codec },
                        set: { state.settings.video.codec = $0 }
                    )) {
                        Text("H.264 (호환성)").tag("h264")
                        Text("H.265 (효율)").tag("h265")
                        Text("AV1 (최신)").tag("av1")
                    }
                    LabeledContent("비트레이트") {
                        Slider(value: Binding(
                            get: { Double(state.settings.video.bitRateMbps) },
                            set: { state.settings.video.bitRateMbps = Int($0) }
                        ), in: 2...50, step: 1) {
                            Text("비트레이트")
                        } minimumValueLabel: {
                            Text("2M")
                        } maximumValueLabel: {
                            Text("50M")
                        }
                        .frame(width: 220)
                        Text("\(state.settings.video.bitRateMbps) Mbps")
                            .monospacedDigit()
                            .frame(width: 70, alignment: .trailing)
                    }
                    Picker("최대 해상도", selection: Binding(
                        get: { state.settings.video.maxSize },
                        set: { state.settings.video.maxSize = $0 }
                    )) {
                        Text("원본").tag(0)
                        Text("1280px").tag(1280)
                        Text("1920px").tag(1920)
                        Text("2560px").tag(2560)
                    }
                    Picker("프레임 제한", selection: Binding(
                        get: { state.settings.video.maxFPS },
                        set: { state.settings.video.maxFPS = $0 }
                    )) {
                        Text("제한 없음").tag(0)
                        Text("30fps").tag(30)
                        Text("60fps").tag(60)
                        Text("120fps").tag(120)
                    }
                }

                Section("동작") {
                    Toggle("오디오 전송", isOn: Binding(
                        get: { state.settings.audioEnabled },
                        set: { state.settings.audioEnabled = $0 }
                    ))
                    Toggle("미러링 중 화면 끄기", isOn: Binding(
                        get: { state.settings.turnScreenOff },
                        set: { state.settings.turnScreenOff = $0 }
                    ))
                    Toggle("깨어있기 유지 (USB)", isOn: Binding(
                        get: { state.settings.stayAwake },
                        set: { state.settings.stayAwake = $0 }
                    ))
                    Toggle("터치 표시", isOn: Binding(
                        get: { state.settings.showTouches },
                        set: { state.settings.showTouches = $0 }
                    ))
                    Toggle("고급 입력 (uhid 물리 키보드·마우스)", isOn: Binding(
                        get: { state.settings.advancedInput },
                        set: { state.settings.advancedInput = $0 }
                    ))
                    Text("고급 입력을 켜면 폰에 가상 키보드/마우스가 연결되어 호버·게임 키·한글 IME가 물리키보드처럼 동작합니다. 일부 앱에서 문제가 있으면 끄세요.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
            .tabItem { Label("화면", systemImage: "display") }

            Form {
                Section("DeX 가상 디스플레이") {
                    Text("앱 창은 각자 독립된 가상 디스플레이에서 실행됩니다. 폰 화면은 그대로 유지됩니다.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Picker("해상도", selection: Binding(
                        get: { "\(state.settings.virtualDisplay.width)x\(state.settings.virtualDisplay.height)" },
                        set: { parts in
                            let dims = parts.split(separator: "x").compactMap { Int($0) }
                            if dims.count == 2 {
                                state.settings.virtualDisplay.width = dims[0]
                                state.settings.virtualDisplay.height = dims[1]
                            }
                        }
                    )) {
                        Text("1280 × 720").tag("1280x720")
                        Text("1600 × 900").tag("1600x900")
                        Text("1920 × 1080 (DeX 표준)").tag("1920x1080")
                        Text("2560 × 1440").tag("2560x1440")
                    }
                    LabeledContent("밀도 (DPI)") {
                        Slider(value: Binding(
                            get: { Double(state.settings.virtualDisplay.density) },
                            set: { state.settings.virtualDisplay.density = Int($0) }
                        ), in: 120...480, step: 20) {
                            Text("DPI")
                        } minimumValueLabel: {
                            Text("120")
                        } maximumValueLabel: {
                            Text("480")
                        }
                        .frame(width: 220)
                        Text("\(state.settings.virtualDisplay.density)")
                            .monospacedDigit()
                            .frame(width: 40, alignment: .trailing)
                    }
                    Text("낮은 DPI = 큰 레이아웃(태블릿/데스크톱 느낌), 높은 DPI = 폰 레이아웃.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("캐시") {
                    LabeledContent("앱 아이콘 캐시") {
                        HStack {
                            Text(cacheSize)
                            Button("지우기") {
                                clearIconCache()
                            }
                        }
                    }
                    Text("앱 아이콘/라벨 캐시입니다. 지워도 다음 실행 시 다시 만들어집니다.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
            .tabItem { Label("DeX", systemImage: "square.grid.2x2") }

            AboutView()
                .tabItem { Label("정보", systemImage: "info.circle") }
        }
        .frame(width: 560, height: 480)
        .task {
            cacheSize = Self.iconCacheSize()
        }
    }

    private func clearIconCache() {
        try? FileManager.default.removeItem(at: Binaries.iconCache)
        try? FileManager.default.createDirectory(at: Binaries.iconCache, withIntermediateDirectories: true)
        cacheSize = Self.iconCacheSize()
    }

    private static func iconCacheSize() -> String {
        let dir = Binaries.iconCache
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: [.fileSizeKey]
        ) else { return "0 B" }
        let bytes = files.reduce(Int64(0)) { total, url in
            total + Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
        return ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}
