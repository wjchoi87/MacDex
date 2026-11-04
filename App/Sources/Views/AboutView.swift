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
                // 표 형태: 항목 이름 열(오른쪽 정렬, 고정 폭) + 설명 열, 행마다 구분선
                Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 16, verticalSpacing: 0) {
                    ForEach(Array(features.enumerated()), id: \.offset) { index, feature in
                        if index > 0 {
                            Divider().gridCellUnsizedAxes(.horizontal)
                        }
                        GridRow {
                            Text(feature.name)
                                .fontWeight(.medium)
                                .foregroundStyle(.secondary)
                                .frame(width: 84, alignment: .trailing)
                            Text(feature.detail)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .padding(.vertical, 7)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
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

    private let features: [(name: String, detail: String)] = [
        ("미러링", "초저지연 하드웨어 디코딩 (scrcpy 기반)"),
        ("DeX 데스크톱", "MacDroid 데스크톱 — 앱을 창으로, 독·상태표시줄·바탕화면 아이콘"),
        ("입력", "물리 키보드·마우스·호버·한글 입력"),
        ("무선", "Wi-Fi 페어링/연결, 같은 네트워크 자동 발견"),
        ("프라이버시", "모든 통신은 로컬(USB/Wi-Fi) — 서버 없음"),
    ]

    private var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0.0"
    }
}
