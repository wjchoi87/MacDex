import Foundation
import Darwin

/// CLI 세션: 떼어낸(detached) scrcpy 프로세스를 pid 파일로 관리.
/// 정책: CLI가 종료해도 scrcpy 창은 계속 떠 있어야 한다(에이전트가 띄우고 나서 검사/조작).
///   파이프는 부모 종료 시 닫혀 EPIPE로 자식이 죽을 수 있으므로 stdio를 로그 파일로 돌린다.
struct CLISession: Codable {
    enum Kind: String, Codable { case app, mirror }
    var id: String
    var kind: Kind
    var serial: String
    var package: String?
    var pid: Int32
    var logPath: String
    var displayId: Int?
    var startedAt: Date
    /// 이 세션이 절전 방지를 켤 때의 원래 설정값(복구용). 뒤늦은 세션이면 nil(복구 안 함).
    var stayOnPrevious: Int?
}

enum CLISessions {

    static var dir: URL {
        let d = Binaries.appSupport.appending(path: "sessions", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    private static func fileURL(_ id: String) -> URL {
        dir.appending(path: id + ".json")
    }

    // MARK: 실행

    /// scrcpy를 detached로 실행하고 세션 파일을 남긴다.
    /* 정책: stdio는 로그 파일과 /dev/null로 완전히 돌린다 — 부모(CLI)가 종료해도 창이
       살아있어야 하고, 하네스/호출자의 stdout 파이프를 고아 프로세스가 물고 있으면
       호출자가 EOF를 못 받아 멈추는 사고가 생긴다(실측). display id는 로그가 아니라
       기기의 dumpsys mDisplayId diff로 감지한다(scrcpy stderr는 파일 리다이렉트 시
       풀 버퍼링되어 로그 폴링이 불안정 — 실측).
       세션 시작 시 절전 방지(stay_on)를 켜고 원래 값을 세션에 저장, 마지막 세션
       종료 시 복구한다. */
    static func spawnScrcpy(kind: CLISession.Kind, serial: String, package: String?, arguments: [String]) async throws -> CLISession {
        guard FileManager.default.isExecutableFile(atPath: Binaries.scrcpy.path) else {
            throw ADBError.failure("scrcpy를 찾을 수 없습니다 — MacDroid.app 설치 또는 MACDROID_BIN 설정")
        }
        let id = UUID().uuidString.prefix(8).lowercased()
        let logPath = dir.appending(path: "scrcpy-\(id).log")
        FileManager.default.createFile(atPath: logPath.path, contents: nil)
        guard let logHandle = try? FileHandle(forWritingTo: logPath) else {
            throw ADBError.failure("로그 파일 생성 실패: \(logPath.path)")
        }

        let process = Process()
        process.executableURL = Binaries.scrcpy
        process.arguments = arguments
        process.environment = Binaries.processEnvironment
        process.standardOutput = logHandle
        process.standardError = logHandle
        process.standardInput = FileHandle.nullDevice
        do { try process.run() } catch {
            throw ADBError.failure("scrcpy 실행 실패: \(error.localizedDescription)")
        }

        // 절전 방지: 이 기기의 첫 세션이면 현재값을 저장하고 올린다
        let isFirst = !loadAll().contains { $0.serial == serial }
        let stayOnPrevious = isFirst ? await ADB.enableStayAwake(serial: serial) : nil

        let session = CLISession(
            id: String(id), kind: kind, serial: serial, package: package,
            pid: process.processIdentifier, logPath: logPath.path,
            displayId: nil, startedAt: Date(), stayOnPrevious: stayOnPrevious
        )
        if let data = try? JSONEncoder().encode(session) {
            try? data.write(to: fileURL(session.id), options: .atomic)
        }
        return session
    }

    /// 세션 정보 갱신(예: displayId 캡처 후).
    static func update(_ session: CLISession, displayId: Int?) throws {
        var s = session
        s.displayId = displayId
        if let data = try? JSONEncoder().encode(s) {
            try? data.write(to: fileURL(s.id), options: .atomic)
        }
    }

    /// 기기 dumpsys의 mDisplayId diff로 새 가상 디스플레이 id를 기다린다.
    static func pollNewDisplayId(serial: String, before: Set<Int>, timeout: TimeInterval) async -> Int? {
        let start = Date()
        while Date().timeIntervalSince(start) < timeout {
            if let ids = try? await ADB.displayIds(serial: serial),
               let new = ids.first(where: { !before.contains($0) }) {
                return new
            }
            try? await Task.sleep(for: .milliseconds(500))
        }
        return nil
    }

    // MARK: 종료

    static func loadAll() -> [CLISession] {
        let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        return files
            .filter { $0.pathExtension == "json" }
            .compactMap { try? JSONDecoder().decode(CLISession.self, from: Data(contentsOf: $0)) }
    }

    private static func isAlive(_ pid: Int32) -> Bool {
        kill(pid, 0) == 0
    }

    /// pid에 SIGTERM. 절전 방지 복구: 이 기기의 마지막 세션이 끝나면 원래값으로 되돌린다.
    @discardableResult
    static func terminate(_ session: CLISession) async -> Bool {
        let wasAlive = isAlive(session.pid)
        if wasAlive { kill(session.pid, SIGTERM) }
        try? FileManager.default.removeItem(at: fileURL(session.id))
        if !loadAll().contains(where: { $0.serial == session.serial }),
           let previous = session.stayOnPrevious {
            await ADB.restoreStayAwake(serial: session.serial, previous: previous)
        }
        return wasAlive
    }

    static func terminate(serial: String, package: String) async throws -> Int {
        var count = 0
        for session in loadAll()
        where session.serial == serial && session.kind == .app && session.package == package {
            if await terminate(session) { count += 1 }
        }
        return count
    }

    static func terminateAll(serial: String, kind: CLISession.Kind? = nil) async throws -> Int {
        var count = 0
        for session in loadAll()
        where session.serial == serial && (kind == nil || session.kind == kind) {
            if await terminate(session) { count += 1 }
        }
        return count
    }
}
