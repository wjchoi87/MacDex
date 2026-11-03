import SwiftUI

/// 정보 — 앱 정보 + 오픈소스 고지.
struct AboutView: View {
    @State private var noticeText: String = ""

    var body: some View {
        Form {
            Section {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(spacing: 14) {
                        Image(systemName: "rectangle.on.rectangle")
                            .font(.system(size: 36, weight: .medium))
                            .foregroundStyle(Color.accentColor)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("MacDroid")
                                .font(.title3.bold())
                            Text("버전 \(appVersion) · 맥에서 쓰는 안드로이드 데스크톱")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }

            Section("특징") {
                LabeledContent("미러링", value: "초저지연 하드웨어 디코딩 (scrcpy 기반)")
                LabeledContent("DeX 모드", value: "앱마다 독립 가상 디스플레이 창")
                LabeledContent("입력", value: "물리 키보드·마우스·호버·한글 IME")
                LabeledContent("무선", value: "Wi-Fi 페어링/연결, mDNS 자동 발견")
                LabeledContent("프라이버시", value: "모든 통신은 로컬(USB/Wi-Fi) — 서버 없음")
            }

            Section("오픈소스 고지") {
                ScrollView {
                    Text(noticeText.isEmpty ? "LICENSES/NOTICE.md를 불러올 수 없습니다." : noticeText)
                        .font(.system(size: 11, design: .monospaced))
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(height: 200)
            }
        }
        .task {
            if let url = Bundle.main.url(forResource: "NOTICE", withExtension: "md", subdirectory: "LICENSES") {
                noticeText = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
            } else if let url = Bundle.main.url(forResource: "NOTICE", withExtension: "md") {
                noticeText = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
            }
        }
    }

    private var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0.0"
    }
}
