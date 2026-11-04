import Foundation
import Network
import AppKit

/// 로컬 네트워크 권한 상태.
enum LocalNetworkStatus: Sendable, Equatable {
    case granted       // 앱이 LAN 기기에 실제 TCP 연결 성공 — 권한 있음
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
                    // ready는 사용자가 프롬프트에 답하기 전에도 온다 — 허용 증거가 아니다.
                    // 결과 수신(granted) 또는 정책 거부(denied)를 기다린다.
                    break
                case .failed(let error):
                    finish(isPolicyDenied(error) ? .denied : .unknown)
                case .waiting(let error):
                    if isPolicyDenied(error) { finish(.denied) }
                default:
                    break
                }
            }
            // 결과 수신은 허용 증거가 아니다(실측: LAN TCP 거부 상태에서도 캐시 결과가 온다).
            // 이 함수는 프롬프트 유발 + 정책 거부 감지용 — 허용 판정은 LanProbe(TCP)가 한다.
            browser.start(queue: .global())
        }
    }

    /// NWError에서 로컬 네트워크 정책 거부(kDNSServiceErr_PolicyDenied) 판별.
    static func isPolicyDenied(_ error: NWError) -> Bool {
        if (error as NSError).code == -65570 { return true }
        let text = error.debugDescription
        return text.contains("PolicyDenied") || text.contains("-65570")
    }

    /// 권한 판정용 직접 LAN 대상 — 이 Mac의 사설 IPv4 서브넷 게이트웨이 추정(x.y.z.1, 자신이 .1이면 .2).
    /// 연결 성공 여부가 아니라 path의 정책 거부 여부만 본다.
    static func lanProbeTarget() -> String? {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return nil }
        defer { freeifaddrs(head) }
        for cursor in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let entry = cursor.pointee
            guard let addr = entry.ifa_addr, addr.pointee.sa_family == UInt8(AF_INET),
                  String(cString: entry.ifa_name).hasPrefix("en") else { continue }
            var sin = sockaddr_in()
            memcpy(&sin, addr, MemoryLayout<sockaddr_in>.size)
            let octets = withUnsafeBytes(of: sin.sin_addr.s_addr) { Array($0) }
            let (a, b) = (Int(octets[0]), Int(octets[1]))
            let isPrivate = a == 10 || (a == 172 && (16...31).contains(b)) || (a == 192 && b == 168)
            guard isPrivate else { continue }
            let last = octets[3] == 1 ? 2 : 1
            return "\(octets[0]).\(octets[1]).\(octets[2]).\(last)"
        }
        return nil
    }

    /// 시스템 설정의 로컬 네트워크 패널 열기.
    static func openSystemSettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_LocalNetwork")!
        NSWorkspace.shared.open(url)
    }
}
