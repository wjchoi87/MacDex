import Foundation
import SwiftUI

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
        startDeviceMonitoring()
        startWirelessSweep()
        adoptOrphanSessions()
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
                lastError = "기기 감시 시작 실패: \(error.localizedDescription)"
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

    /// 주기 스윕: 기억한 무선 기기가 목록에 없으면 재접속 시도(폰 쪽 adbd이 살아나면 붙는다).
    private func startWirelessSweep() {
        guard wirelessSweepTask == nil else { return }
        wirelessSweepTask = Task { @MainActor in
            while !Task.isCancelled, !isShuttingDown {
                try? await Task.sleep(for: .seconds(20))
                guard !isShuttingDown else { return }
                pruneDeadExternalSessions()  // 사용자가 창을 직접 닫은 고아 세션 정리
                let hosts = UserDefaults.standard.stringArray(forKey: Self.wirelessHostsKey) ?? []
                let online = Set(devices.map(\.serial))
                let missing = hosts.filter { !online.contains($0) }
                guard !missing.isEmpty else { continue }
                var restored: [String] = []
                for host in missing {
                    if (try? await ADB.connect(host: host)) != nil {
                        restored.append(host)
                    }
                }
                if !restored.isEmpty {
                    toast = "무선 기기 다시 연결됨: \(restored.joined(separator: ", "))"
                }
            }
        }
    }

    /// 감시(재)시작 직후: adb 서버가 재시작되며 무선 연결이 풀렸다면 즉시 한 번 재접속.
    private func reconnectRememberedWirelessHosts() {
        let hosts = UserDefaults.standard.stringArray(forKey: Self.wirelessHostsKey) ?? []
        let online = Set(devices.map(\.serial))
        let missing = hosts.filter { !online.contains($0) }
        guard !missing.isEmpty else { return }
        Task {
            for host in missing {
                _ = try? await ADB.connect(host: host)
            }
        }
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
    }

    /// 무선(ip:port 형태 시리얼) 기기를 기억해 뒀다가 연결이 풀리면 자동 재접속에 쓴다.
    private func rememberWirelessHosts(from snapshot: [Device]) {
        let hosts = snapshot.map(\.serial).filter { $0.contains(":") }
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
            title: "MacDroid · \(device.displayModel) 미러링"
        )
        let args = Scrcpy.mirrorArguments(device: device, settings: settings, audioAllowed: true)
        beginStayAwakeIfNeeded(serial: device.serial)
        do {
            let process = try Scrcpy.launch(arguments: args, sessionID: session.key)
            session.attach(process)
            sessions.removeAll { $0.id == session.id }
            sessions.append(session)
        } catch {
            lastError = "미러링 시작 실패: \(error.localizedDescription)"
        }
    }

    /// DeX 앱 창(가상 디스플레이).
    /* 변경 전 정책: 같은 앱 창이 이미 있으면 무조건 무시했다(사용자에게 피드백 없음).
       변경 후 정책: forceNewInstance면 '+' 프리픽스로 새 인스턴스를 추가 실행하고,
         기본값은 여전히 무시 — 중복 확인 다이얼로그는 LauncherView가 담당한다.
       이유: Android의 앱 task 재사용 특성상 의도치 않은 이중 실행을 막되,
         사용자가 명시적으로 원할 때는 별도 창을 띄워주기 위함.
       영향 범위: DeX 런처의 동일 앱 재실행 경로만. */
    func launchAppWindow(for device: Device, app: AndroidApp, forceNewInstance: Bool = false) {
        let id = Scrcpy.makeID(serial: device.serial, mode: .app, package: app.package)
        if !forceNewInstance, sessions.contains(where: { $0.id == id }) { return }

        var session = ScrcpySession(
            id: id,
            deviceSerial: device.serial,
            mode: .app,
            title: "MacDroid · \(app.displayLabel)"
        )
        // 오디오 중복 방지: 이 기기에 이미 오디오 켜진 세션이 있으면 이번 창은 무음
        let audioAllowed = !sessions.contains { $0.deviceSerial == device.serial }
        let args = Scrcpy.appArguments(device: device, app: app, settings: settings,
                                       audioAllowed: audioAllowed, forceNewInstance: forceNewInstance)
        beginStayAwakeIfNeeded(serial: device.serial)
        do {
            let process = try Scrcpy.launch(arguments: args, sessionID: session.key)
            session.attach(process)
            sessions.append(session)
        } catch {
            lastError = "앱 창 실행 실패: \(error.localizedDescription)"
        }
    }

    /// DeX 데스크톱 전체(가상 디스플레이 + 삼성 SecondaryLauncher).
    /* 정책: 미러와 같은 규칙 — 기기당 DeX 데스크톱 창은 1개. 다시 누르면 기존 창을
       종료하고 새로 띄운다. 디스플레이 생성은 비동기(scrcpy 서버 푸시)이므로,
       실행 전 디스플레이 목록을 저장해 두고 새 id가 생기면 그 위에 DeX 런처를 올린다. */
    func launchDexDesktop(for device: Device) {
        guard ADB.supportsDexDesktop(device) else {
            lastError = "DeX 데스크톱은 Samsung(DeX 지원) 기기에서 사용할 수 있습니다."
            return
        }
        let existing = sessions.first { $0.deviceSerial == device.serial && $0.mode == .dex }
        existing?.terminate()

        var session = ScrcpySession(
            id: Scrcpy.makeID(serial: device.serial, mode: .dex, package: nil),
            deviceSerial: device.serial,
            mode: .dex,
            title: "MacDroid · \(device.displayModel) DeX 데스크톱"
        )
        let audioAllowed = !sessions.contains { $0.deviceSerial == device.serial }
        let args = Scrcpy.dexArguments(device: device, settings: settings, audioAllowed: audioAllowed)
        beginStayAwakeIfNeeded(serial: device.serial)

        Task { @MainActor in
            // 새 디스플레이 감지 기준선 — scrcpy 실행 '전'에 반드시 확보한다
            let before = Set((try? await ADB.displayIds(serial: device.serial)) ?? [])
            do {
                let process = try Scrcpy.launch(arguments: args, sessionID: session.key)
                session.attach(process)
                sessions.removeAll { $0.id == session.id }
                sessions.append(session)

                // 디스플레이가 생기면 DeX 런처를 올린다. 못 찾으면 창을 정리하고 안내.
                guard let displayId = await ADB.newDisplayId(serial: device.serial, excluding: before) else {
                    if sessions.contains(where: { $0.key == session.key }) {
                        session.terminate()
                        lastError = "DeX 디스플레이를 만들지 못했습니다. 잠시 후 다시 시도하세요."
                    }
                    return
                }
                try await ADB.startDexLauncher(serial: device.serial, displayId: displayId)
            } catch {
                lastError = "DeX 데스크톱 실행 실패: \(error.localizedDescription)"
            }
        }
    }

    /// 기존 창을 종료하고 새로 실행(확인 다이얼로그에서 '기존 창 닫고 새로 실행'을 고른 경로).
    func relaunchAppWindow(for device: Device, app: AndroidApp) {
        let id = Scrcpy.makeID(serial: device.serial, mode: .app, package: app.package)
        for session in sessions where session.id == id {
            session.terminate()
            sessions.removeAll { $0.key == session.key }  // onExit 대기 없이 즉시 제거(재실행 id 충돌 방지)
        }
        launchAppWindow(for: device, app: app)
    }

    func stopSession(_ session: ScrcpySession) {
        session.terminate()
        // 고아 입양 세션은 onExit 이벤트가 없으므로 여기서 직접 목록 정리
        if session.externalPID != nil {
            sessions.removeAll { $0.key == session.key }
            endStayAwakeIfLast(serial: session.deviceSerial)
        }
    }

    func stopSessions(for serial: String) {
        for session in sessions where session.deviceSerial == serial {
            session.terminate()
        }
        // 고아 입양분 즉시 정리(일반 세션은 onExit가 지운다)
        sessions.removeAll { $0.deviceSerial == serial && $0.externalPID != nil }
        endStayAwakeIfLast(serial: serial)
    }

    /* 변경 전 정책: 세션 목록은 앱 프로세스 메모리에만 있어서, 앱이 강제 종료되거나
       재빌드로 재시작되면 살아남은 scrcpy 창(미러/DeX/앱)을 목록에서 볼 수도 닫을 수도 없었다.
       변경 후 정책: 시작 시 이 번들의 scrcpy 경로로 떠 있는 프로세스와 CLI 세션 파일(pid)을
       스캔해 세션으로 "입양"한다 — 목록에 보이고 닫기로 종료할 수 있다.
       영향 범위: 앱 재시작 전후 창 관리. 입양 세션은 pid kill로 종료한다. */
    private func adoptOrphanSessions() {
        Task {
            var found: [Int32: ScrcpySession] = [:]

            // 1) 실행 중인 우리 scrcpy 프로세스(경로로 판별 — 다른 scrcpy와 구분)
            if let result = try? await ProcessRunner.run(
                URL(fileURLWithPath: "/bin/ps"),
                arguments: ["-axo", "pid=,command="],
                environment: Binaries.processEnvironment
            ) {
                for rawLine in result.stdout.split(separator: "\n") {
                    let line = String(rawLine).trimmingCharacters(in: .whitespaces)
                    guard line.hasPrefix(Binaries.scrcpy.path) else { continue }
                    let parts = line.split(separator: " ").map(String.init)
                    guard let pid = Int32(parts.first ?? "") else { continue }
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
                    case .mirror: label = "미러링"
                    case .app: label = "앱 창 (\(package ?? "?"))"
                    case .dex: label = "DeX 데스크톱"
                    }
                    found[pid] = ScrcpySession(
                        id: Scrcpy.makeID(serial: serial, mode: mode, package: package),
                        deviceSerial: serial, mode: mode,
                        title: "MacDroid · \(serial) \(label)",
                        externalPID: pid
                    )
                }
            }

            // 살아 있는 것만 입양
            var adopted = found.values.filter { $0.isProcessAlive }
            guard !adopted.isEmpty else { return }

            // 이미 등록된 세션(pid 보유)과 중복되지 않게
            adopted.removeAll { orphan in
                sessions.contains { $0.deviceSerial == orphan.deviceSerial && $0.id == orphan.id && $0.externalPID == nil }
            }

            // 입양 세션이 있는 기기는 stay_on이 켜져 있을 수 있다 — 마지막 세션 종료 시 0으로 복구되도록 기록
            let serials = Set(adopted.map(\.deviceSerial))
            for serial in serials where stayOnSaved[serial] == nil {
                let current = try? await ADB.shell(serial: serial, "settings get global stay_on_while_plugged_in")
                let value = Int(current?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "") ?? 0
                if value != 0 { stayOnSaved[serial] = 0 }
            }

            sessions.append(contentsOf: adopted)
            toast = "이전 실행의 창 \(adopted.count)개를 다시 관리합니다 (닫기로 종료 가능)"
        }
    }

    /// 고아 입양 세션 중 프로세스가 죽은 것(사용자가 창을 직접 닫은 경우)을 목록에서 제거.
    private func pruneDeadExternalSessions() {
        let dead = sessions.filter { $0.externalPID != nil && !$0.isProcessAlive }
        guard !dead.isEmpty else { return }
        let deadKeys = Set(dead.map(\.key))
        sessions.removeAll { deadKeys.contains($0.key) }
        for session in dead { endStayAwakeIfLast(serial: session.deviceSerial) }
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

    func pair(host: String, code: String) {
        guard !host.isEmpty, !code.isEmpty else {
            lastError = "주소와 페어링 코드를 입력하세요."
            return
        }
        busyMessage = "페어링 중…"
        Task {
            do {
                _ = try await ADB.pair(host: host, code: code)
                busyMessage = nil
                toast = "페어링 완료. 이제 연결할 수 있습니다."
            } catch {
                busyMessage = nil
                lastError = "페어링 실패: \(error.localizedDescription)"
            }
        }
    }

    func connect(host: String) {
        guard !host.isEmpty else { return }
        busyMessage = "연결 중…"
        Task {
            do {
                _ = try await ADB.connect(host: host)
                busyMessage = nil
                toast = "\(host) 연결됨"
            } catch {
                busyMessage = nil
                lastError = "연결 실패: \(error.localizedDescription)"
            }
        }
    }

    /// USB 기기를 무선으로 전환.
    func enableWireless(for device: Device) {
        busyMessage = "무선 모드로 전환 중… (몇 초 걸림)"
        Task {
            do {
                let host = try await ADB.enableWireless(serial: device.serial)
                busyMessage = nil
                toast = "무선 연결 완료: \(host) — USB 케이블을 뽑아도 됩니다"
            } catch {
                busyMessage = nil
                lastError = "무선 전환 실패: \(error.localizedDescription)"
            }
        }
    }

    // MARK: 연결 복구

    /// 원클릭 연결 복구(초보자용): adb 서버 재시작 → 기억된 무선 재접속 → mDNS 발견 접속 → 목록 갱신.
    /* 정책: kill-server로 track-devices가 죽어도 자가회복이 되살리므로 안전하다.
       Mac에서 할 수 있는 것들을 전부 돌리고, 그래도 기기가 없으면 폰 쪽 점검
       (USB '파일 전송' 모드 / 무선 디버깅 ON)을 다음 단계로 제시한다. */
    func recoverConnections() {
        guard busyMessage == nil else { return }
        busyMessage = "연결 복구 중… (몇 초 걸림)"
        Task {
            // 1) adb 서버 완전 재시작 — 고착/이상 상태 리셋
            _ = try? await ProcessRunner.run(Binaries.adb, arguments: ["kill-server"],
                                             environment: Binaries.processEnvironment)
            _ = try? await ProcessRunner.run(Binaries.adb, arguments: ["start-server"],
                                             environment: Binaries.processEnvironment)

            // 2) 기억해 둔 무선 기기 재접속
            var connected: [String] = []
            for host in UserDefaults.standard.stringArray(forKey: Self.wirelessHostsKey) ?? [] {
                if (try? await ADB.connect(host: host)) != nil {
                    connected.append(host)
                }
            }

            // 3) mDNS로 지금 발견되는 무선 디버깅 기기도 자동 접속(페어링 대기 서비스는 제외)
            if let services = try? await ADB.mdnsServices() {
                for service in services
                where service.name.hasPrefix("무선 디버깅") && !connected.contains(service.address) {
                    if (try? await ADB.connect(host: service.address)) != nil {
                        connected.append(service.address)
                    }
                }
            }

            // 4) 목록 즉시 갱신(감시 자가회복 스냅샷을 기다리지 않는다)
            if let list = try? await ADB.listDevices() {
                applyDeviceSnapshot(list)
            }

            busyMessage = nil
            if !connected.isEmpty {
                toast = "복구 완료 — \(connected.joined(separator: ", ")) 연결됨"
            } else if devices.contains(where: { $0.state == .online }) {
                toast = "복구 완료 — USB 기기가 인식되었습니다"
            } else {
                lastError = "복구 후에도 기기가 보이지 않습니다. 폰에서 확인하세요 — ① USB 알림 → '파일 전송' 모드 선택 ② 개발자 옵션 → 무선 디버깅 켜기 ③ 맥과 같은 Wi-Fi인지 확인"
            }
        }
    }

    // MARK: 파일 전송

    func pushFiles(_ files: [URL], to device: Device) {
        guard !files.isEmpty else { return }
        busyMessage = "파일 전송 중… \(files.count)개"
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
                toast = "전송 완료: 폰의 Download 폴더에 저장됨"
            } else {
                lastError = "전송 실패: \(failures.joined(separator: ", "))"
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
