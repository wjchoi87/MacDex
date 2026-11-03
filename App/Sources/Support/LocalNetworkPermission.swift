import Foundation
import Network
import AppKit

/// 로컬 네트워크 권한 상태.
enum LocalNetworkStatus: Sendable, Equatable {
    case granted       // 탐색 동작(결과 수신 또는 브라우저 ready) — 권한 있음
    case denied        // 정책 거부(kDNSServiceErr_PolicyDenied) — 시스템 설정에서 허용 필요
    case unknown       // 판단 불가(타임아웃 등) — 안내만 약하게
}

/// 로컬 네트워크 권한 탐지기.
/* 정책: adb server를 MacDroid가 띄우면 macOS는 server를 앱 소속으로 간주해 로컬 네트워크
   프라이버시를 적용한다. 권한이 없으면 LAN unicast/mDNS가 조용히 차단되는데(실측:
   "No route to host" + mdns 빈 목록), 앱 입장에선 원인이 안 보인다.
   NWBrowser로 _adb-tls-connect._tcp Bonjour 탐색을 직접 시도하면 (1) 권한 프롬프트를
   유발하고 (2) 정책 거부(kDNSServiceErr_PolicyDenied = -65570)를 에러로 받아
   "거부됨"을 확정할 수 있다. */
enum LocalNetworkPermission {

    /// Bonjour 탐색으로 권한을 점검한다. 결과 수신/ready → granted, 정책 거부 → denied.
    static func probe(timeout: TimeInterval = 3) async -> LocalNetworkStatus {
        // 콜백이 여러 스레드에서 오므로 1회성 완료를 락으로 보장한다
        final class Once: @unchecked Sendable {
            private let lock = NSLock()
            private var done = false
            func run(_ block: () -> Void) {
                lock.lock()
                let already = done
                done = true
                lock.unlock()
                if !already { block() }
            }
        }
        let once = Once()

        return await withCheckedContinuation { continuation in
            let browser = NWBrowser(
                for: .bonjour(type: "_adb-tls-connect._tcp", domain: nil),
                using: .tcp
            )
            let finish: @Sendable (LocalNetworkStatus) -> Void = { status in
                once.run {
                    browser.cancel()
                    continuation.resume(returning: status)
                }
            }
            // 타임아웃: 응답이 없으면 판단 불가 — 늦게 깨어나도 Once가 중복 resume를 막는다
            Task.detached {
                try? await Task.sleep(for: .seconds(timeout))
                finish(.unknown)
            }

            browser.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    finish(.granted)   // 탐색 정상 동작 = 권한 허용됨
                case .failed(let error):
                    finish(isPolicyDenied(error) ? .denied : .unknown)
                case .waiting(let error):
                    if isPolicyDenied(error) { finish(.denied) }
                default:
                    break
                }
            }
            browser.browseResultsChangedHandler = { results, _ in
                if !results.isEmpty { finish(.granted) }   // 실제 서비스 수신 = 확정 허용
            }
            browser.start(queue: .global())
        }
    }

    /// NWError에서 로컬 네트워크 정책 거부(kDNSServiceErr_PolicyDenied) 판별.
    private static func isPolicyDenied(_ error: NWError) -> Bool {
        if (error as NSError).code == -65570 { return true }
        let text = error.debugDescription
        return text.contains("PolicyDenied") || text.contains("-65570")
    }

    /// 시스템 설정의 로컬 네트워크 패널 열기.
    static func openSystemSettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_LocalNetwork")!
        NSWorkspace.shared.open(url)
    }
}
