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
    }

    func stopSessions(for serial: String) {
        for session in sessions where session.deviceSerial == serial {
            session.terminate()
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
