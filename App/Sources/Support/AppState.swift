import Foundation
import SwiftUI
import Darwin

/// 앱 전역 상태 저장소.
/// 정책: 모든 상태 변이는 MainActor. adb/scrcpy 비동기 결과만 받아들인다.
@MainActor
@Observable
final class AppState {

    static let shared = AppState()

    // MARK: 상태

    private(set) var devices: [Device] = []
    private(set) var sessions: [ScrcpySession] = []

    var settings: MirrorSettings = MirrorSettings.load() {
        didSet { settings.save() }
    }

    // 진행/에러 표시
    var lastError: String?
    var busyMessage: String?
    var toast: String?

    var hasRunningSession: Bool { !sessions.isEmpty }

    private var monitorProcess: StreamingProcess?
    private var monitorRestartTask: Task<Void, Never>?
    private var wirelessSweepTask: Task<Void, Never>?
    private var isShuttingDown = false
    private var detailTasks: [String: Task<Void, Never>] = [:]

    /// 같은 Wi-Fi의 무선 디버깅 기기 탐색 — 앱 전역(페어링 시트를 열지 않아도 항상 돈다).
    let discovery = LanDiscovery()
    /// 주소별 마지막 자동 연결 시도 시각 — 같은 주소는 20초에 한 번만 두드린다(포트가 바뀌면 새 주소).
    private var autoConnectTried: [String: Date] = [:]

    /// 기기별 절전 방지(stay_on) 이전값 — DeX/미러 세션 동안 기기가 잠들지 않게 했다가 복구.
    private var stayOnSaved: [String: Int] = [:]

    /// 이전에 봤던 무선(ip:port) 기기 주소 — adb 서버 재시작으로 연결이 풀려도 자동 재접속한다.
    private static let wirelessHostsKey = "MacDroid.rememberedWirelessHosts"

    /// 세션이 시작될 때: 이 기기의 첫 세션이면 절전 방지를 켜고 이전값을 저장.
    private func beginStayAwakeIfNeeded(serial: String) {
        guard !sessions.contains(where: { $0.deviceSerial == serial }),
              stayOnSaved[serial] == nil else { return }
        Task {
            if let previous = await ADB.enableStayAwake(serial: serial) {
                stayOnSaved[serial] = previous
            }
        }
    }

    /// 세션이 모두 끝났을 때: 절전 방지를 원래값으로 복구.
    private func endStayAwakeIfLast(serial: String) {
        guard !sessions.contains(where: { $0.deviceSerial == serial }),
              let previous = stayOnSaved[serial] else { return }
        stayOnSaved[serial] = nil
        Task {
            await ADB.restoreStayAwake(serial: serial, previous: previous)
        }
    }

    private init() {
        SessionEvents.shared.addHandler { [weak self] sessionID in
            Task { @MainActor in
                self?.removeSession(id: sessionID)
            }
        }
    }

    // MARK: 시작/종료

    func start() {
        guard monitorProcess == nil, monitorRestartTask == nil else { return }
        // 로컬 네트워크 권한 프롬프트를 먼저 유발 — MacDroid가 띄우는 adb 서버는 이 권한을 따른다
        Task { _ = await LocalNetworkPermission.probe(timeout: 3) }
        cleanupOrphanTrackers()
        startDeviceMonitoring()
        discovery.onServiceResolved = { [weak self] service in
            self?.autoConnect(service)
        }
        discovery.start()
        startWirelessSweep()
        adoptOrphanSessions()
    }

    /// 이전 실행이 남긴 고아 adb track-devices 정리.
    /* 정책: 앱이 정상 종료 경로(applicationWillTerminate)를 밟지 않고 죽으면(Xcode 재실행,
       강제 종료) track-devices가 PPID 1로 남아 계속 쌓인다(실측 3개).
       커맨드가 '우리 번들 adb 경로 + track-devices'이고 PPID==1인 프로세스만 SIGTERM —
       SDK/홈브루 adb나 현재 실행 중인 우리 감시(PPID=앱)는 건드리지 않는다. */
    private func cleanupOrphanTrackers() {
        DispatchQueue.global(qos: .utility).async {
            for entry in ProcessScan.snapshot()
            where entry.ppid == 1
                && entry.command.hasPrefix(Binaries.adb.path)
                && entry.command.contains("track-devices") {
                kill(entry.pid, SIGTERM)
            }
        }
    }

    /* 정책: adb 서버는 Mac의 다른 adb 클라이언트(홈브루/SDK 등)와 공유된다. 버전이 다른
       클라이언트가 실행되면 서버가 죽었다 재시작되고, 이 앱의 track-devices도 함께 죽는다.
       예전엔 이때 앱을 재시작해야 했다(실측 — 기기 목록이 멈추고 '자동 검색 안 됨'으로 보임).
       이제 감시가 죽으면 1초 뒤 스스로 되살리고, 서버 재시작으로 풀린 무선 연결도
       기억해 둔 주소로 자동 재접속한다. */
    private func startDeviceMonitoring() {
        Task {
            // adb 서버 기동(첫 실행 지연 방지 + 다른 클라이언트가 죽인 경우 부활)
            _ = try? await ProcessRunner.run(
                Binaries.adb, arguments: ["start-server"], environment: Binaries.processEnvironment
            )
            do {
                monitorProcess = try await ADB.trackDevices(
                    onUpdate: { [weak self] snapshot in
                        Task { @MainActor in
                            self?.applyDeviceSnapshot(snapshot)
                        }
                    },
                    onExit: { [weak self] _ in
                        Task { @MainActor in
                            self?.handleMonitorExit()
                        }
                    }
                )
                reconnectRememberedWirelessHosts()
            } catch {
                lastError = String(localized: "기기 감시 시작 실패: \(error.localizedDescription)")
                scheduleMonitorRestart()
            }
        }
    }

    private func handleMonitorExit() {
        monitorProcess = nil
        guard !isShuttingDown else { return }
        scheduleMonitorRestart()
    }

    private func scheduleMonitorRestart() {
        guard monitorRestartTask == nil else { return }
        monitorRestartTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(1))
            monitorRestartTask = nil
            guard !isShuttingDown else { return }
            startDeviceMonitoring()
        }
    }

    /// 주기 스윕: 기억한 무선 기기가 online이 아니면 재접속 시도(폰 쪽 adbd이 살아나면 붙는다).
    private func startWirelessSweep() {
        guard wirelessSweepTask == nil else { return }
        wirelessSweepTask = Task { @MainActor in
            while !Task.isCancelled, !isShuttingDown {
                try? await Task.sleep(for: .seconds(20))
                guard !isShuttingDown else { return }
                pruneDeadExternalSessions()  // 사용자가 창을 직접 닫은 고아 세션 정리
                // 사용자 작업(연결·페어링·복구) 중에는 같은 주소를 동시에 두드리지 않는다
                guard busyMessage == nil else { continue }
                // 같은 Wi-Fi에서 보이는데 안 붙어 있는 폰은 다시 자동 연결(폰이 잠깐 끊겼다 돌아온 경우)
                for service in discovery.services where service.kind == .connect {
                    autoConnect(service)
                }
                let restored = await reconnectRememberedHosts()
                if !restored.isEmpty {
                    toast = String(localized: "무선 기기 다시 연결됨: \(restored.joined(separator: ", "))")
                }
            }
        }
    }

    /// 감시(재)시작 직후: adb 서버가 재시작되며 무선 연결이 풀렸다면 즉시 한 번 재접속.
    private func reconnectRememberedWirelessHosts() {
        Task { await reconnectRememberedHosts() }
    }

    /// 기억한 무선 기기 재접속. 실제로 device 상태가 된 호스트를 돌려준다.
    /* 변경 전 정책: 목록에 '없는' 주소만 adb connect로 다시 붙였다(출력 문자열 판정).
       결함: offline으로 남은 전송은 '목록에 있음'으로 보여 영영 재접속되지 않았고, 토글할 때마다
       바뀌는 무선 디버깅 포트를 계속 두드렸으며, 같은 폰이 다른 포트로 이미 붙어 있어도 중복
       전송을 만들었다(같은 adbd에 이중 연결 → 끊김 유발).
       변경 후 정책: online이 아닌 주소만 connectVerified로 재접속(잔류 offline 정리 포함), 같은 IP가
       이미 online이면 건너뛰고, 'Connection refused'면 바뀐 포트로 보고 기억에서 뺀다. */
    @discardableResult
    private func reconnectRememberedHosts() async -> [String] {
        let hosts = UserDefaults.standard.stringArray(forKey: Self.wirelessHostsKey) ?? []
        let online = devices.filter { $0.state == .online }
        let onlineSerials = Set(online.map(\.serial))
        let onlineIPs = Set(online.compactMap(\.wirelessIP))
        var restored: [String] = []
        var stale: [String] = []
        for host in hosts where !onlineSerials.contains(host) {
            if let ip = host.split(separator: ":").first.map(String.init), onlineIPs.contains(ip) { continue }
            // 서버 mDNS 전송으로 이미 붙어 있는 폰(이름에 ip가 없다)은 다시 붙이지 않는다 — 중복 전송 방지
            if discovery.services.contains(where: { service in
                service.address == host && online.contains { $0.serial.hasPrefix(service.instance) }
            }) { continue }
            switch await ADB.connectVerified(host: host) {
            case .online: restored.append(host)
            case .refused: stale.append(host)
            default: break
            }
        }
        if !stale.isEmpty {
            // 루프 중 새로 기억된 주소를 덮어쓰지 않도록 현재 값을 다시 읽어 뺀다
            let current = UserDefaults.standard.stringArray(forKey: Self.wirelessHostsKey) ?? []
            UserDefaults.standard.set(current.filter { !stale.contains($0) }, forKey: Self.wirelessHostsKey)
        }
        return restored
    }

    /// 앱 종료 시 모든 scrcpy 세션 정리(고아 프로세스 방지).
    func shutdownAll() {
        isShuttingDown = true
        monitorRestartTask?.cancel()
        wirelessSweepTask?.cancel()
        for session in sessions {
            session.terminate()
        }
        monitorProcess?.terminate()
        sessions.removeAll()
        for desktop in desktops.values { desktop.stop() }
        desktops.removeAll()
    }

    // MARK: 기기 스냅샷 적용

    private func applyDeviceSnapshot(_ snapshot: [Device]) {
        let old = devices
        var merged: [Device] = []
        for newDevice in snapshot {
            // 기존 상세 정보 보존(같은 시리얼)
            if let previous = old.first(where: { $0.serial == newDevice.serial }) {
                var d = newDevice
                d.model = previous.model
                d.brand = previous.brand
                d.manufacturer = previous.manufacturer
                d.androidVersion = previous.androidVersion
                d.sdkInt = previous.sdkInt
                d.screenSize = previous.screenSize
                d.serialNo = previous.serialNo
                if newDevice.state == .online, previous.state != .online || previous.batteryLevel == nil {
                    scheduleDetailFetch(for: d)
                }
                merged.append(d)
            } else {
                merged.append(newDevice)
                if newDevice.state == .online {
                    scheduleDetailFetch(for: newDevice)
                }
            }
        }
        // 사라진 기기의 세션은 scrcpy가 스스로 종료함(onExit → removeSession). 여기선 상태만 정리.
        devices = merged
        rememberWirelessHosts(from: merged)
        dropDuplicateWirelessTransports(merged)
    }

    /// 같은 폰이 서버 mDNS 전송(adb-<serial>-xxx._adb-tls-connect._tcp)과 ip:port 전송으로 동시에 붙어 있으면 ip:port를 내린다.
    /* 정책: 같은 adbd에 전송 2개는 끊김·명령 대상 혼동을 부른다(실측: 기억된 주소 재접속과 서버 mDNS 자동연결이 겹침).
       서버 mDNS 전송이 서버가 스스로 관리하는 쪽이라 그것을 남긴다. 매핑은 앱의 Bonjour 탐색(인스턴스 ↔ ip:port)으로 한다. */
    private func dropDuplicateWirelessTransports(_ snapshot: [Device]) {
        let online = snapshot.filter { $0.state == .online }
        for service in discovery.services where service.kind == .connect {
            guard online.contains(where: { $0.serial == service.address }),
                  online.contains(where: { $0.serial.hasPrefix(service.instance) }) else { continue }
            Task { await ADB.disconnect(serial: service.address) }
        }
    }

    /// 무선(ip:port 형태 시리얼) 기기를 기억해 뒀다가 연결이 풀리면 자동 재접속에 쓴다.
    private func rememberWirelessHosts(from snapshot: [Device]) {
        // online으로 확인된 주소만 기억한다 — offline 잔류(실패한 connect의 찌꺼기)를 기억하면
        // 20초마다 영원히 다시 두드리게 된다(실측: 192.168.0.1:80 offline 잔류).
        let hosts = snapshot.filter { $0.state == .online }.map(\.serial).filter { $0.contains(":") }
        guard !hosts.isEmpty else { return }
        var saved = UserDefaults.standard.stringArray(forKey: Self.wirelessHostsKey) ?? []
        for host in hosts where !saved.contains(host) {
            saved.append(host)
        }
        if saved.count > 8 { saved = Array(saved.suffix(8)) }  // 최근 것 위주로 상한
        UserDefaults.standard.set(saved, forKey: Self.wirelessHostsKey)
    }

    private func scheduleDetailFetch(for device: Device) {
        guard detailTasks[device.serial] == nil else { return }
        detailTasks[device.serial] = Task {
            let detailed = await ADB.fillDeviceDetails(device)
            if let index = devices.firstIndex(where: { $0.serial == detailed.serial }) {
                devices[index] = detailed
            }
            detailTasks[detailed.serial] = nil
        }
    }

    func refreshDevice(_ device: Device) {
        var d = device
        d.batteryLevel = nil
        scheduleDetailFetch(for: d)
    }

    func device(for serial: String) -> Device? {
        devices.first { $0.serial == serial }
    }

    // MARK: 세션 실행

    /// 실화면 미러. 이미 떠 있는 미러가 있으면 먼저 종료(이중 미러 금지 정책).
    func launchMirror(for device: Device) {
        let existing = sessions.first { $0.deviceSerial == device.serial && $0.mode == .mirror }
        existing?.terminate()

        var session = ScrcpySession(
            id: Scrcpy.makeID(serial: device.serial, mode: .mirror, package: nil),
            deviceSerial: device.serial,
            mode: .mirror,
            title: String(localized: "MacDroid · \(device.displayModel) 미러링")
        )
        let args = Scrcpy.mirrorArguments(device: device, settings: settings, audioAllowed: true)
        beginStayAwakeIfNeeded(serial: device.serial)
        do {
            let process = try Scrcpy.launch(arguments: args, sessionID: session.key)
            session.attach(process)
            sessions.removeAll { $0.id == session.id }
            sessions.append(session)
        } catch {
            lastError = String(localized: "미러링 시작 실패: \(error.localizedDescription)")
        }
    }

    // MARK: 데스크톱

    /// 기기별 MacDroid 데스크톱 세션(데스크톱 창이 열려 있는 동안).
    private(set) var desktops: [String: DesktopSession] = [:]

    /// 기기의 데스크톱 세션(없으면 만든다 — 실제 스트림은 데스크톱 창이 크기를 알려 줄 때 시작).
    func desktop(for serial: String) -> DesktopSession {
        if let existing = desktops[serial] { return existing }
        let session = DesktopSession(serial: serial, appState: self)
        desktops[serial] = session
        return session
    }

    /// 데스크톱 창이 닫히면 스트림·창 추적을 정리한다.
    func endDesktop(serial: String) {
        desktops.removeValue(forKey: serial)?.stop()
    }

    /// 앱을 MacDroid 데스크톱 안의 창으로 연다(데스크톱 창은 호출한 뷰가 openWindow로 띄운다).
    /* 변경 전 정책: 앱마다 scrcpy(가상 디스플레이+인코더)를 따로 띄우거나, 삼성 데스크톱 화면을 그대로 미러했다.
       변경 후 정책: 데스크톱 세션의 가상 디스플레이 1개에 freeform 창으로 열고(am start, 0.1초), MacDroid가
         그 창 영역만 잘라 우리 데스크톱(배경화면·상태표시줄·독·내비바) 안의 창으로 그린다.
       영향 범위: 앱 런처·기기 상세의 앱 실행. 데스크톱이 아직 준비 중이면 준비되는 즉시 연다. */
    func launchAppWindow(for device: Device, app: AndroidApp, forceNewInstance: Bool = false) {
        desktop(for: device.serial).launch(app, newInstance: forceNewInstance)
    }

    /// 기존 창을 끄고 새로 실행.
    func relaunchAppWindow(for device: Device, app: AndroidApp) {
        desktop(for: device.serial).launch(app, restart: true)
    }

    func stopSession(_ session: ScrcpySession) {
        session.terminate()
        /* 변경 전 정책: 소유 세션은 onExit 이벤트가 오면 제거했다 — 실사용 보고에서
           창은 닫히는데 목록 항목이 남고 재클릭도 무반응이었다(이벤트 경로가 컨텍스트에
           따라 끊기는 사례). 변경 후 정책: 닫기는 즉시 목록에서 제거한다(이중 제거 무해).
           onExit는 사용자가 창을 직접 닫은 경우의 정리 경로로만 쓴다. */
        sessions.removeAll { $0.key == session.key }
        endStayAwakeIfLast(serial: session.deviceSerial)
    }

    func stopSessions(for serial: String) {
        for session in sessions where session.deviceSerial == serial {
            session.terminate()
        }
        sessions.removeAll { $0.deviceSerial == serial }
        endStayAwakeIfLast(serial: serial)
    }

    /* 변경 전 정책: 세션 목록은 앱 프로세스 메모리에만 있어서, 앱이 강제 종료되거나
       재빌드로 재시작되면 살아남은 scrcpy 창(미러/DeX/앱)을 목록에서 볼 수도 닫을 수도 없었다.
       변경 후 정책: 시작 시 이 번들의 scrcpy 경로로 떠 있는 프로세스와 CLI 세션 파일(pid)을
       스캔해 세션으로 "입양"한다 — 목록에 보이고 닫기로 종료할 수 있다.
       영향 범위: 앱 재시작 전후 창 관리. 입양 세션은 pid kill로 종료한다. */
    private func adoptOrphanSessions() {
        // ps 스캔은 ProcessScan(GCD 동기)으로 — ProcessRunner 경로가 앱 시작 시점에
        // 묶이는 사례를 실측했다(고아 정리와 같은 이유).
        DispatchQueue.global(qos: .utility).async { [weak self] in
            var found: [Int32: ScrcpySession] = [:]

            // 1) 실행 중인 우리 scrcpy 프로세스(경로로 판별 — 다른 scrcpy와 구분)
            for entry in ProcessScan.snapshot() {
                guard entry.command.hasPrefix(Binaries.scrcpy.path) else { continue }
                let parts = entry.command.split(separator: " ").map(String.init)
                let args = Array(parts.dropFirst())

                guard let sIndex = args.firstIndex(of: "-s"), sIndex + 1 < args.count else { continue }
                let serial = args[sIndex + 1]

                let startApp = args.first(where: { $0.hasPrefix("--start-app=") })?
                    .dropFirst("--start-app=".count).trimmingCharacters(in: CharacterSet(charactersIn: "+"))
                let hasNewDisplay = args.contains { $0.hasPrefix("--new-display") }

                let mode: ScrcpySession.Mode
                var package: String?
                if let startApp, !startApp.isEmpty {
                    mode = .app
                    package = startApp
                } else if hasNewDisplay {
                    mode = .dex
                } else {
                    mode = .mirror
                }
                let label: String
                switch mode {
                case .mirror: label = String(localized: "미러링")
                case .app: label = String(localized: "앱 창 (\(package ?? "?"))")
                case .dex: label = String(localized: "DeX 데스크톱")
                }
                found[entry.pid] = ScrcpySession(
                    id: Scrcpy.makeID(serial: serial, mode: mode, package: package),
                    deviceSerial: serial, mode: mode,
                    title: "MacDroid · \(serial) \(label)",
                    externalPID: entry.pid
                )
            }

            // 살아 있는 것만 입양
            var adopted = found.values.filter { $0.isProcessAlive }
            guard !adopted.isEmpty else { return }

            Task { @MainActor [weak self] in
                guard let self else { return }
                // 이미 등록된 세션(pid 보유)과 중복되지 않게
                adopted.removeAll { orphan in
                    self.sessions.contains { $0.deviceSerial == orphan.deviceSerial && $0.id == orphan.id && $0.externalPID == nil }
                }
                guard !adopted.isEmpty else { return }

                // 입양 세션이 있는 기기는 stay_on이 켜져 있을 수 있다 — 복구 기준 기록
                let serials = Set(adopted.map(\.deviceSerial))
                for serial in serials where self.stayOnSaved[serial] == nil {
                    let current = try? await ADB.shell(serial: serial, "settings get global stay_on_while_plugged_in")
                    let value = Int(current?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "") ?? 0
                    if value != 0 { self.stayOnSaved[serial] = 0 }
                }

                self.sessions.append(contentsOf: adopted)
                self.toast = String(localized: "이전 실행의 창 \(adopted.count)개를 다시 관리합니다 (닫기로 종료 가능)")
            }
        }
    }

    /// 죽은 세션 정리 — 고아 입양분뿐 아니라 onExit가 늦거나 안 온 소유 세션도
    /// 프로세스가 죽었으면 제거한다(20초 주기 안전망).
    private func pruneDeadExternalSessions() {
        let dead = sessions.filter { !$0.isProcessAlive }
        guard !dead.isEmpty else { return }
        let deadKeys = Set(dead.map(\.key))
        sessions.removeAll { deadKeys.contains($0.key) }
        for session in dead {
            endStayAwakeIfLast(serial: session.deviceSerial)
            }
    }

    private func removeSession(id: String) {
        // id 파라미터는 1회성 key(UUID)다 — 동일 id 재실행 시 신세션 오삭제 방지
        let ended = sessions.first { $0.key == id }
        sessions.removeAll { $0.key == id }
        if let ended {
            endStayAwakeIfLast(serial: ended.deviceSerial)
        }
    }

    // MARK: 무선 연결

    /* 변경 전 정책: adb connect/pair 출력 문자열만 보고 성공/실패를 정했고, 실패 원인은 추측 안내였다.
       결함: offline 잔류 전송에도 "연결됨"이 떴고, LAN 실패의 진짜 원인(adb 서버를 띄운 프로세스에
       로컬 네트워크 권한 없음)을 구분하지 못해 사용자는 폰만 의심했다.
       변경 후 정책: connect는 connectVerified로 실제 상태(device)까지 확인한다. 사설 LAN 대상이
       도달 불가/시간 초과면 앱이 직접 그 ip:port에 TCP로 닿는지 재본다 —
         · 앱은 닿음 → 서버만 막힌 것 → 서버를 MacDroid 소속으로 재시작하고 1회 재시도
         · 앱도 권한 거부 → 시스템 설정 안내
         · 앱도 못 닿음 → 네트워크/주소 문제 안내
       busyMessage가 있으면 새 시도를 막는다(동시 connect·스윕 경합 방지).
       영향 범위: 페어링 시트(코드·IP 직접·자동 발견). */
    func pair(host rawHost: String, code rawCode: String) {
        let host = rawHost.trimmingCharacters(in: .whitespacesAndNewlines)
        let code = rawCode.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !host.isEmpty, !code.isEmpty else {
            lastError = String(localized: "주소와 페어링 코드를 입력하세요.")
            return
        }
        guard busyMessage == nil else { return }
        lastError = nil
        busyMessage = String(localized: "페어링 중… (12초 안에 안 되면 자동 중단)")
        Task {
            var result = await Self.attemptPair(host: host, code: code)
            if case .failure(let error) = result, Self.isNetworkPairFailure(error), Self.isPrivateLANHost(host) {
                switch await Self.appReach(host) {
                case .reachable:
                    busyMessage = Self.restartingServerMessage
                    await ADB.restartServer()
                    result = await Self.attemptPair(host: host, code: code)
                case .localNetworkDenied:
                    busyMessage = nil
                    lastError = Self.localNetworkDeniedMessage
                    return
                case .unreachable, nil:
                    break
                }
            }
            busyMessage = nil
            switch result {
            case .success:
                toast = String(localized: "페어링 완료 — 자동으로 연결합니다")
                // 페어링 전엔 notAuthenticated였던 같은 폰의 connect 서비스를 즉시 다시 붙인다
                autoConnectTried.removeAll()
                for service in discovery.services where service.kind == .connect {
                    autoConnect(service)
                }
            case .failure(let error):
                lastError = Self.pairFailureMessage(host: host, error: error)
            }
        }
    }

    func connect(host rawHost: String) {
        let host = Self.normalizedHost(rawHost)
        guard !host.isEmpty else { return }
        guard busyMessage == nil else { return }
        lastError = nil
        busyMessage = String(localized: "연결 중… \(host)")
        Task {
            let result = await connectWithRecovery(host: host)
            busyMessage = nil
            switch result {
            case .localNetworkDenied:
                lastError = Self.localNetworkDeniedMessage
            case .outcome(let outcome, let serverRestarted):
                report(outcome, host: host, serverRestarted: serverRestarted)
            }
        }
    }

    private enum ConnectResult {
        case outcome(ADB.ConnectOutcome, serverRestarted: Bool)
        case localNetworkDenied
    }

    /// connectVerified + 서버 권한 복구(앱은 닿는데 서버만 못 닿으면 서버를 MacDroid 소속으로 재시작 후 1회 재시도).
    private func connectWithRecovery(host: String) async -> ConnectResult {
        var outcome = await ADB.connectVerified(host: host)
        var serverRestarted = false
        if Self.isLanNetworkFailure(outcome, host: host) {
            switch await Self.appReach(host) {
            case .reachable:
                busyMessage = Self.restartingServerMessage
                await ADB.restartServer()
                serverRestarted = true
                outcome = await ADB.connectVerified(host: host)
            case .localNetworkDenied:
                return .localNetworkDenied
            case .unreachable, nil:
                break
            }
        }
        return .outcome(outcome, serverRestarted: serverRestarted)
    }

    /// 발견된 무선 디버깅 기기 자동 연결.
    /* 변경 전 정책: 같은 Wi-Fi의 기기는 페어링 시트 '자동 발견' 탭을 열고 '연결'을 눌러야만 붙었다.
         앱을 켜도 아무것도 안 뜨고, 무엇을 해야 하는지 응답이 없었다(실사용 피드백).
       변경 후 정책: 앱 시작부터 Bonjour 탐색을 상시로 돌리고, 새로 해석된 _adb-tls-connect 서비스는
         (같은 폰이 이미 online이 아니면) 자동 connect한다 — 주소당 20초에 한 번, 20초 스윕에서도 다시 시도
         (실측: 앱 재시작 직후 잠깐 붙었다 끊긴 폰을 '이미 시도함'으로 남겨 영영 재접속하지 않았다). 서버가 로컬 네트워크 권한에
         막혔으면 connectWithRecovery가 서버를 MacDroid 소속으로 재시작한다.
         페어링이 안 된 폰(notAuthenticated)이면 페어링 방법을 바로 안내한다.
       변경 이유: "한 번 페어링하면 켜자마자 붙는" 흐름 — 사용자가 경로를 찾게 하지 않는다.
       영향 범위: 같은 LAN에서 무선 디버깅이 켜진 모든 폰. 사용자 작업(busyMessage) 중엔 끝날 때까지 대기.
         '다시 찾기'/'연결 복구'/페어링 성공 시에는 간격 없이 즉시 재시도한다. */
    private func autoConnect(_ service: LanDiscovery.Service) {
        guard service.kind == .connect, !isShuttingDown, !isOnline(service) else { return }
        if let last = autoConnectTried[service.address], Date().timeIntervalSince(last) < 20 { return }
        autoConnectTried[service.address] = Date()
        Task {
            while busyMessage != nil {
                try? await Task.sleep(for: .milliseconds(500))
            }
            // adb 서버도 LAN 권한이 있으면 mDNS로 스스로 붙는다(이름: adb-<serial>-xxx._adb-tls-connect._tcp).
            // 동시에 우리도 ip:port로 붙으면 같은 adbd에 전송이 2개 생긴다(실측) — 잠깐 기다리고 실제 목록으로 확인.
            try? await Task.sleep(for: .seconds(2))
            if let list = try? await ADB.listDevices() {
                applyDeviceSnapshot(list)
            }
            guard !isShuttingDown, !isOnline(service) else { return }
            let name = service.displayName
            busyMessage = String(localized: "\(name) 발견 — 무선으로 자동 연결 중…")
            let result = await connectWithRecovery(host: service.address)
            busyMessage = nil
            switch result {
            case .localNetworkDenied:
                autoConnectTried[service.address] = nil
                lastError = Self.localNetworkDeniedMessage
            case .outcome(.online, _):
                toast = String(localized: "\(name) 무선 연결됨")
                // 그 사이 서버 mDNS 자동연결도 붙었으면 우리 ip:port 전송을 내려 중복을 없앤다
                if let list = try? await ADB.listDevices(),
                   list.contains(where: { $0.state == .online && $0.serial.hasPrefix(service.instance) }) {
                    await ADB.disconnect(serial: service.address)
                }
            case .outcome(.notAuthenticated, _):
                // 페어링 전에는 다시 두드려도 소용없다 — 페어링 성공/다시 찾기까지 재시도 중단(안내 반복 방지)
                autoConnectTried[service.address] = .distantFuture
                lastError = String(localized: "\(name)이(가) 같은 Wi-Fi에 있지만 이 맥과 아직 페어링되지 않았습니다 — '무선 기기 연결'을 누르고, 폰의 무선 디버깅 → '페어링 코드로 기기 페어링'을 열면 주소가 자동으로 채워집니다. 코드만 입력하세요(최초 1회).")
            case .outcome(let outcome, let serverRestarted):
                report(outcome, host: service.address, serverRestarted: serverRestarted)
            }
        }
    }

    /// 이 서비스의 폰이 이미 어떤 전송(USB·LAN·VPN)으로든 online인지.
    private func isOnline(_ service: LanDiscovery.Service) -> Bool {
        devices.contains { device in
            device.state == .online && (
                device.serial == service.address
                || device.serial.hasPrefix(service.instance)
                || device.serial == service.deviceSerial
                || (service.deviceSerial != nil && device.serialNo == service.deviceSerial)
            )
        }
    }

    /// 탐색을 처음부터 다시 + 자동 연결 기록 초기화(권한 허용·페어링 후 재시도).
    func restartDiscovery() {
        autoConnectTried.removeAll()
        discovery.restart()
    }

    private func report(_ outcome: ADB.ConnectOutcome, host: String, serverRestarted: Bool) {
        switch outcome {
        case .online:
            toast = String(localized: "\(host) 연결됨")
        case .unauthorized:
            lastError = String(localized: "\(host) — 폰 화면의 'USB 디버깅을 허용하시겠습니까?'에서 '허용'을 누르면 바로 연결됩니다.")
        case .notAuthenticated:
            lastError = String(localized: "\(host)에 닿았지만 기기가 인증하지 않았습니다. 무선 디버깅 화면의 포트(5555가 아닌 포트)라면 먼저 '페어링 코드' 탭에서 이 맥을 페어링하세요.")
        case .refused:
            lastError = String(localized: "\(host) — 포트가 닫혀 있습니다. 폰의 무선 디버깅 화면에 나온 현재 포트를 확인하세요(무선 디버깅을 다시 켤 때마다 바뀝니다).")
        case .unreachable, .timedOut:
            if serverRestarted {
                lastError = String(localized: "adb 서버를 MacDroid 권한으로 재시작했지만 \(host)에 여전히 닿지 않습니다. 시스템 설정 → 개인정보 보호 및 보안 → 로컬 네트워크에서 MacDroid가 켜져 있는지 확인하세요.")
            } else if Self.isPrivateLANHost(host) {
                lastError = String(localized: "\(host)에 닿을 수 없습니다 — 폰과 맥이 같은 Wi-Fi인지, 폰 IP가 바뀌지 않았는지 확인하세요.")
            } else {
                lastError = String(localized: "\(host) 연결 시간 초과 — 주소·포트를 확인하세요. (VPN이면 폰의 VPN IP:5555, 무선 디버깅 포트는 같은 Wi-Fi에서만 닿습니다)")
            }
        case .failed(let raw):
            lastError = String(localized: "\(host) 연결 실패: \(raw)")
        }
    }

    private static let restartingServerMessage =
        String(localized: "adb 서버가 로컬 네트워크에 닿지 못해 MacDroid 권한으로 재시작합니다… (다른 adb 도구의 연결이 잠시 끊깁니다)")
    private static let localNetworkDeniedMessage =
        String(localized: "MacDroid의 로컬 네트워크 접근이 꺼져 있습니다 — 시스템 설정 → 개인정보 보호 및 보안 → 로컬 네트워크에서 MacDroid를 켜세요.")

    /// 포트가 없으면 tcpip 기본 포트(5555)를 붙인다.
    private static func normalizedHost(_ raw: String) -> String {
        let host = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !host.isEmpty else { return "" }
        return host.contains(":") ? host : host + ":5555"
    }

    /// 사설 LAN 대상의 '도달 불가/시간 초과' — 서버 권한 문제일 수 있는 실패.
    private static func isLanNetworkFailure(_ outcome: ADB.ConnectOutcome, host: String) -> Bool {
        switch outcome {
        case .unreachable, .timedOut: return isPrivateLANHost(host)
        default: return false
        }
    }

    /// 앱 자신이 host(ip:port)에 TCP로 닿는지(파싱 불가면 nil).
    private static func appReach(_ host: String) async -> LanProbe.Reach? {
        let parts = host.split(separator: ":")
        guard parts.count == 2, let port = UInt16(parts[1]) else { return nil }
        return await LanProbe.tcp(host: String(parts[0]), port: port)
    }

    private static func attemptPair(host: String, code: String) async -> Result<Void, Error> {
        do {
            _ = try await ADB.pair(host: host, code: code)
            return .success(())
        } catch {
            return .failure(error)
        }
    }

    /// 네트워크 계열 페어링 실패(코드 오류·거부 제외) — 서버 권한 문제일 수 있다.
    private static func isNetworkPairFailure(_ error: Error) -> Bool {
        if case ProcessError.timedOut = error { return true }
        let text = error.localizedDescription.lowercased()
        return text.contains("unable to start pairing client") || text.contains("no route")
            || text.contains("unreachable")
    }

    private static func pairFailureMessage(host: String, error: Error) -> String {
        let text = error.localizedDescription.lowercased()
        if text.contains("wrong password") {
            return String(localized: "페어링 코드가 틀렸거나 만료됐습니다 — 폰에서 '페어링 코드로 기기 페어링'을 다시 열고, 새 코드와 새 주소(포트 포함)로 시도하세요.")
        }
        if case ProcessError.timedOut = error {
            return String(localized: "페어링 시간 초과(\(host)) — 폰의 '기기 페어링' 창이 열려 있는 동안만 주소·코드가 유효합니다. 주소(포트 포함)를 다시 확인하세요.")
        }
        if text.contains("refused") {
            return String(localized: "\(host) — 페어링 포트가 닫혀 있습니다. 폰의 '기기 페어링' 창을 다시 열어 새 주소를 확인하세요.")
        }
        if isNetworkPairFailure(error) {
            return String(localized: "\(host)에 닿을 수 없습니다 — 폰과 맥이 같은 Wi-Fi인지 확인하세요.")
        }
        return String(localized: "페어링 실패: \(error.localizedDescription)")
    }

    /// 사설 대역(10/8, 172.16/12, 192.168/16, 169.254/16) 판정 — 공인·VPN(100.64/10)은 제외.
    private static func isPrivateLANHost(_ host: String) -> Bool {
        let ip = host.split(separator: ":").first.map(String.init) ?? host
        let octets = ip.split(separator: ".").compactMap { Int($0) }
        guard octets.count == 4 else { return false }
        let (a, b) = (octets[0], octets[1])
        if a == 10 { return true }
        if a == 172 && (16...31).contains(b) { return true }
        if a == 192 && b == 168 { return true }
        if a == 169 && b == 254 { return true }
        return false
    }

    /// USB 기기를 무선으로 전환.
    func enableWireless(for device: Device) {
        busyMessage = String(localized: "무선 모드로 전환 중… (몇 초 걸림)")
        Task {
            do {
                let host = try await ADB.enableWireless(serial: device.serial)
                busyMessage = nil
                toast = String(localized: "무선 연결 완료: \(host) — USB 케이블을 뽑아도 됩니다")
            } catch {
                busyMessage = nil
                lastError = String(localized: "무선 전환 실패: \(error.localizedDescription)")
            }
        }
    }

    // MARK: 연결 복구

    /// 원클릭 연결 복구(초보자용): adb 서버 재시작 → 기억된 무선 재접속 → mDNS 발견 접속 → 목록 갱신.
    /* 정책: kill-server로 track-devices가 죽어도 자가회복이 되살리므로 안전하다.
       Mac에서 할 수 있는 것들을 전부 돌리고, 그래도 기기가 없으면 폰 쪽 점검
       (USB '파일 전송' 모드 / 무선 디버깅 ON)을 다음 단계로 제시한다.
       실무(performRecovery)는 DeX 실행 실패 시 자동 재시도에서도 재사용한다. */
    func recoverConnections() {
        guard busyMessage == nil else { return }
        busyMessage = String(localized: "연결 복구 중… (몇 초 걸림)")
        restartDiscovery()
        Task {
            let connected = await performRecovery()
            busyMessage = nil
            if !connected.isEmpty {
                toast = String(localized: "복구 완료 — \(connected.joined(separator: ", ")) 연결됨")
            } else if devices.contains(where: { $0.state == .online }) {
                toast = String(localized: "복구 완료 — USB 기기가 인식되었습니다")
            } else {
                lastError = String(localized: "복구 후에도 기기가 보이지 않습니다 — ① 폰 USB 알림 → '파일 전송' 모드 ② 폰 개발자 옵션 → 무선 디버깅 켜기 ③ 맥과 같은 Wi-Fi인지 ④ 맥: 시스템 설정 → 개인정보 보호 및 보안 → 로컬 네트워크에서 MacDroid 켜기")
            }
        }
    }

    /// 복구 실무 — 완료를 기다릴 수 있고, 연결에 성공한 호스트를 돌려준다.
    /* 변경 전 정책: 무조건 kill-server → start-server를 MacDroid 번들 adb로 실행했다.
       문제(실측): 터미널/Android Studio가 띄운 정상 동작 서버를 죽이고 MacDroid 소속
       서버로 바꿔 버려, 오히려 LAN(로컬 네트워크 권한)이 끊겼다. kill-server는 같은 Mac의
       다른 adb 클라이언트를 전부 끊는다는 점도 주석으로 남긴다.
       변경 후 정책: 먼저 서버 응답(adb devices, 5초)을 확인하고, 고착(무응답)일 때만
       재시작한다. 권한 거부 상태라면 재시작해도 LAN은 안 풀리므로 안내가 먼저다(탐지는
       PairSheet/연결 실패 메시지가 담당). */
    @discardableResult
    private func performRecovery() async -> [String] {
        // 1) 서버 건강 검사 — 살아 있으면 건드리지 않는다
        let healthy = ((try? await ProcessRunner.run(
            Binaries.adb, arguments: ["devices"],
            environment: Binaries.processEnvironment, timeout: 5
        ))?.succeeded) == true
        if !healthy {
            // 고착 상태만 재시작(다른 adb 클라이언트 연결이 끊긴다는 비용이 있다)
            _ = try? await ProcessRunner.run(Binaries.adb, arguments: ["kill-server"],
                                             environment: Binaries.processEnvironment)
            _ = try? await ProcessRunner.run(Binaries.adb, arguments: ["start-server"],
                                             environment: Binaries.processEnvironment)
        }

        // 2) 기억해 둔 무선 기기 재접속(실제 device 상태까지 확인)
        var connected = await reconnectRememberedHosts()

        // 3) 서버 mDNS가 보는 무선 디버깅 기기도 접속(페어링 대기 서비스는 제외)
        if let services = try? await ADB.mdnsServices() {
            for service in services
            where !service.isPairing && !connected.contains(service.address) {
                if await ADB.connectVerified(host: service.address) == .online {
                    connected.append(service.address)
                }
            }
        }

        // 4) 목록 즉시 갱신(감시 자가회복 스냅샷을 기다리지 않는다)
        if let list = try? await ADB.listDevices() {
            applyDeviceSnapshot(list)
        }
        return connected
    }

    // MARK: 파일 전송

    func pushFiles(_ files: [URL], to device: Device) {
        guard !files.isEmpty else { return }
        busyMessage = String(localized: "파일 전송 중… \(files.count)개")
        Task {
            var failures: [String] = []
            for file in files {
                do {
                    try await ADB.push(serial: device.serial, file: file)
                } catch {
                    failures.append(file.lastPathComponent)
                }
            }
            busyMessage = nil
            if failures.isEmpty {
                toast = String(localized: "전송 완료: 폰의 Download 폴더에 저장됨")
            } else {
                lastError = String(localized: "전송 실패: \(failures.joined(separator: ", "))")
            }
        }
    }

    // MARK: UI 헬퍼

    func showError(_ message: String) {
        lastError = message
    }

    func clearToast() {
        toast = nil
    }
}
