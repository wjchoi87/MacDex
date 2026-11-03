import Foundation
import Network

/// 앱 자신의 LAN TCP 도달성 판정 + Bonjour 서비스 IPv4 해석.
/* 정책: "앱은 닿는데 adb 서버만 못 닿는다"를 구분하기 위한 기준 측정. 앱 자신의
   로컬 네트워크 권한으로 NWConnection을 열어 본다. 거부는 NWPath.unsatisfiedReason
   == .localNetworkDenied로 판정한다. 연결은 ready 즉시 취소한다(데이터 송수신 없음). */
enum LanProbe {

    enum Reach: Sendable, Equatable {
        case reachable
        case localNetworkDenied
        case unreachable
    }

    /// host:port에 앱이 직접 TCP로 닿는지.
    static func tcp(host: String, port: UInt16, timeout: TimeInterval = 3) async -> Reach {
        guard let nwPort = NWEndpoint.Port(rawValue: port) else { return .unreachable }
        return await open(.hostPort(host: NWEndpoint.Host(host), port: nwPort), timeout: timeout).reach
    }

    /// Bonjour 서비스 엔드포인트를 "IPv4:port"로 해석. 도달 판정도 함께 돌려준다(권한 판정 근거).
    static func resolveIPv4(_ endpoint: NWEndpoint, timeout: TimeInterval = 4) async -> (reach: Reach, address: String?) {
        await open(endpoint, timeout: timeout)
    }

    private static func open(_ endpoint: NWEndpoint, timeout: TimeInterval) async -> (reach: Reach, address: String?) {
        await withCheckedContinuation { continuation in
            let parameters = NWParameters.tcp
            // adb는 IPv4 ip:port만 안정적으로 다룬다 — 링크로컬 IPv6 해석을 피한다
            if let ip = parameters.defaultProtocolStack.internetProtocol as? NWProtocolIP.Options {
                ip.version = .v4
            }
            let connection = NWConnection(to: endpoint, using: parameters)
            let once = OnceFlag()
            let finish: @Sendable (Reach, String?) -> Void = { reach, address in
                guard once.claim() else { return }
                connection.stateUpdateHandler = nil
                connection.cancel()
                continuation.resume(returning: (reach, address))
            }
            let denied: @Sendable () -> Bool = {
                connection.currentPath?.unsatisfiedReason == .localNetworkDenied
            }

            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    var address: String?
                    if case .hostPort(let host, let port)? = connection.currentPath?.remoteEndpoint,
                       case .ipv4(let ipv4) = host {
                        let ip = "\(ipv4)".components(separatedBy: "%").first ?? "\(ipv4)"
                        address = "\(ip):\(port.rawValue)"
                    }
                    finish(.reachable, address)
                case .waiting:
                    // 권한 거부는 즉시 확정, 그 외 일시적 경로 문제는 타임아웃까지 재시도에 맡긴다
                    if denied() { finish(.localNetworkDenied, nil) }
                case .failed:
                    finish(denied() ? .localNetworkDenied : .unreachable, nil)
                default:
                    break
                }
            }
            connection.start(queue: .global(qos: .utility))
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout) {
                finish(denied() ? .localNetworkDenied : .unreachable, nil)
            }
        }
    }
}

/// 같은 Wi-Fi의 무선 디버깅 기기 탐색 — 앱이 직접 Bonjour를 본다.
/* 변경 전 정책: '자동 발견' 목록을 adb 서버의 `adb mdns services`에서 가져왔다.
   실측 결함: (1) 서버를 띄운 프로세스(터미널·Android Studio·권한 없는 MacDroid)에 로컬
   네트워크 권한이 없으면 서버 mDNS가 조용히 비어 있다 — 같은 순간 macOS(dns-sd)는 폰의
   _adb-tls-connect 서비스를 보는데 서버는 0건. (2) ProcessRunner 행으로 목록 갱신 자체가
   멈출 수 있었다.
   변경 후 정책: NWBrowser로 _adb-tls-connect/_adb-tls-pairing을 직접 찾고 NWConnection으로
   IPv4 ip:port를 해석한다(앱 자신의 권한만 필요). 해석되지 않는 오래된 캐시 레코드는 목록에
   올리지 않고 8초마다 다시 해석을 시도한다. 연결은 해석된 ip:port로 adb connect.
   영향 범위: 페어링 시트 '자동 발견' 탭. */
@MainActor
@Observable
final class LanDiscovery {

    struct Service: Identifiable, Equatable {
        enum Kind: Sendable { case connect, pairing }

        let instance: String      // 예: adb-R3CXC0B854E-HwzEEU
        let kind: Kind
        let address: String       // 해석된 IPv4 ip:port

        var id: String { (kind == .pairing ? "P|" : "C|") + instance }

        /// 인스턴스 이름에 담긴 기기 시리얼(adb-<serial>-<random>) — 이미 연결된 폰 판별용.
        var deviceSerial: String? {
            guard instance.hasPrefix("adb-") else { return nil }
            let body = instance.dropFirst("adb-".count)
            guard let dash = body.lastIndex(of: "-") else { return nil }
            let serial = String(body[body.startIndex..<dash])
            return serial.isEmpty ? nil : serial
        }
    }

    private(set) var services: [Service] = []
    private(set) var permission: LocalNetworkStatus = .unknown
    private(set) var isBrowsing = false

    private var browsers: [NWBrowser] = []
    /// 아직 해석되지 않은(또는 실패한) 서비스 — id → (이름, 종류, 엔드포인트)
    private var pending: [String: (instance: String, kind: Service.Kind, endpoint: NWEndpoint)] = [:]
    private var resolving: Set<String> = []
    private var retryTask: Task<Void, Never>?

    func start() {
        guard browsers.isEmpty else { return }
        isBrowsing = true
        for (type, kind) in [("_adb-tls-connect._tcp", Service.Kind.connect),
                             ("_adb-tls-pairing._tcp", Service.Kind.pairing)] {
            let browser = NWBrowser(for: .bonjour(type: type, domain: nil), using: .tcp)
            browser.stateUpdateHandler = { [weak self] state in
                var isDenied = false
                switch state {
                case .waiting(let error), .failed(let error):
                    isDenied = LocalNetworkPermission.isPolicyDenied(error)
                default:
                    break
                }
                if isDenied {
                    Task { @MainActor in self?.permission = .denied }
                }
            }
            browser.browseResultsChangedHandler = { [weak self] results, _ in
                var found: [(String, NWEndpoint)] = []
                for result in results {
                    if case .service(let name, _, _, _) = result.endpoint {
                        found.append((name, result.endpoint))
                    }
                }
                let snapshot = found
                Task { @MainActor in self?.apply(snapshot, kind: kind) }
            }
            browser.start(queue: .global(qos: .utility))
            browsers.append(browser)
        }
        retryTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(8))
                self?.resolvePending()
            }
        }
    }

    func stop() {
        browsers.forEach { $0.cancel() }
        browsers.removeAll()
        retryTask?.cancel()
        retryTask = nil
        services.removeAll()
        pending.removeAll()
        resolving.removeAll()
        isBrowsing = false
    }

    /// 처음부터 다시 탐색(새로고침 버튼).
    func restart() {
        stop()
        permission = .unknown
        start()
    }

    /* 권한 판정: Bonjour 결과 수신은 허용 증거가 아니다 — 실측으로 LAN TCP가 거부된 상태에서도
       캐시된 서비스가 browse 결과로 왔다. 해석(TCP 연결) 결과로만 판정한다:
       ready → granted, localNetworkDenied → denied. */
    private func apply(_ found: [(String, NWEndpoint)], kind: Service.Kind) {
        let prefix = kind == .pairing ? "P|" : "C|"
        let liveIDs = Set(found.map { prefix + $0.0 })
        // 사라진 서비스 정리(폰에서 무선 디버깅을 끄거나 페어링 화면을 닫은 경우)
        services.removeAll { $0.kind == kind && !liveIDs.contains($0.id) }
        for id in pending.keys where id.hasPrefix(prefix) && !liveIDs.contains(id) {
            pending[id] = nil
        }
        for (instance, endpoint) in found {
            let id = prefix + instance
            guard !services.contains(where: { $0.id == id }) else { continue }
            pending[id] = (instance, kind, endpoint)
        }
        resolvePending()
    }

    private func resolvePending() {
        for (id, entry) in pending where !resolving.contains(id) {
            resolving.insert(id)
            Task { [weak self] in
                let resolved = await LanProbe.resolveIPv4(entry.endpoint)
                self?.finishResolve(id: id, instance: entry.instance, kind: entry.kind,
                                    reach: resolved.reach, address: resolved.address)
            }
        }
    }

    private func finishResolve(id: String, instance: String, kind: Service.Kind,
                               reach: LanProbe.Reach, address: String?) {
        resolving.remove(id)
        switch reach {
        case .localNetworkDenied: permission = .denied
        case .reachable: permission = .granted
        case .unreachable: break
        }
        // 해석 실패(오래된 캐시 레코드 등)는 숨긴 채 다음 주기에 다시 시도
        guard let address, pending[id] != nil else { return }
        pending[id] = nil
        services.removeAll { $0.id == id }
        services.append(Service(instance: instance, kind: kind, address: address))
        services.sort { ($0.kind == .connect ? 0 : 1, $0.instance) < ($1.kind == .connect ? 0 : 1, $1.instance) }
    }
}
