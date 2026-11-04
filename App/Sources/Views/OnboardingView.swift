import SwiftUI

/// 첫 실행 온보딩 — USB 디버깅 활성화 가이드 + 실시간 연결 감지.
/// 정책: 기기가 연결되면 자동으로 닫힌다(가이드가 성공을 알려주는 UX).
struct OnboardingView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss

    private var connected: Bool {
        appState.devices.contains { $0.state == .online }
    }

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 10) {
                Image(systemName: "rectangle.on.rectangle")
                    .font(.system(size: 44, weight: .medium))
                    .foregroundStyle(Color.accentColor)
                Text("폰을 맥에 연결하세요")
                    .font(.title2.bold())
                Text("MacDroid는 Android Debug Bridge로 통신합니다.\n아래 3단계면 준비 끝입니다.")
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
            }
            .padding(.top, 32)
            .padding(.bottom, 20)

            VStack(alignment: .leading, spacing: 14) {
                GuideStep(number: 1,
                          title: String(localized: "개발자 옵션 켜기"),
                          detail: String(localized: "설정 → 휴대전화 정보 → 소프트웨어 정보 → 빌드 번호를 7번 누릅니다."))
                GuideStep(number: 2,
                          title: String(localized: "USB 디버깅 허용"),
                          detail: String(localized: "설정 → 개발자 옵션 → USB 디버깅을 켭니다. (무선 디버깅도 같이 켜두면 편합니다)"))
                GuideStep(number: 3,
                          title: String(localized: "USB 케이블 연결"),
                          detail: String(localized: "폰에 뜨는 'USB 디버깅 허용' 알림에서 이 컴퓨터를 허용하세요."))

                HStack(spacing: 8) {
                    Image(systemName: connected ? "checkmark.circle.fill" : "dot.radiowaves.left.and.right")
                        .foregroundStyle(connected ? Color.green : Color.secondary)
                    Text(connected ? String(localized: "기기 연결됨! 잠시 후 자동으로 닫힙니다") : String(localized: "기기 연결 대기 중…"))
                        .font(.callout)
                        .foregroundStyle(connected ? Color.green : Color.secondary)
                }
                .padding(.top, 4)
            }
            .padding(.horizontal, 36)

            Spacer(minLength: 12)

            HStack {
                Button("다시 보지 않기") {
                    UserDefaults.standard.set(true, forKey: "MacDroid.onboardingDone")
                    dismiss()
                }
                Spacer()
                Button("무선으로 연결하기") {
                    NotificationCenter.default.post(name: .macdroidOpenPair, object: nil)
                    dismiss()
                }
                Button("완료") {
                    UserDefaults.standard.set(true, forKey: "MacDroid.onboardingDone")
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .disabled(!connected)
            }
            .padding(24)
        }
        .frame(width: 520, height: 480)
    }
}

struct GuideStep: View {
    let number: Int
    let title: String
    let detail: String

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Text("\(number)")
                .font(.headline)
                .foregroundStyle(.white)
                .frame(width: 26, height: 26)
                .background(Circle().fill(Color.accentColor))
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.headline)
                Text(detail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
