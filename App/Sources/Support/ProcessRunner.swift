import Foundation
import Darwin

struct ProcessResult: Sendable {
    let status: Int32
    let stdout: String
    let stderr: String

    var output: String { stdout + stderr }

    var succeeded: Bool { status == 0 }
}

enum ProcessError: Error, LocalizedError {
    case launchFailed(String)
    case timedOut(String, seconds: Int)

    var errorDescription: String? {
        switch self {
        case .launchFailed(let message): return message
        case .timedOut(let name, let seconds): return "\(name)이(가) \(seconds)초 내에 응답하지 않았습니다"
        }
    }
}

/// GCD 콜백 스레드 사이에서 공유하는 바이트 버퍼(tailLimit이면 마지막 N바이트만 보관).
final class LockedBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()
    private let tailLimit: Int?

    init(tailLimit: Int? = nil) {
        self.tailLimit = tailLimit
    }

    func append(_ chunk: Data) {
        lock.lock()
        defer { lock.unlock() }
        data.append(chunk)
        if let tailLimit, data.count > tailLimit {
            data.removeFirst(data.count - tailLimit)
        }
    }

    var value: Data {
        lock.lock()
        defer { lock.unlock() }
        return data
    }
}

/// 여러 스레드에서 호출돼도 한 번만 통과시키는 플래그.
final class OnceFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false

    /// 처음 호출이면 true.
    func claim() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if done { return false }
        done = true
        return true
    }
}

/// 파이프를 GCD readabilityHandler로 EOF까지 비동기 소비한다(콜백은 GCD 스레드).
private func drainPipe(_ handle: FileHandle,
                       onChunk: @escaping @Sendable (Data) -> Void,
                       onEOF: @escaping @Sendable () -> Void) {
    let eof = OnceFlag()
    handle.readabilityHandler = { readable in
        let chunk = readable.availableData
        if chunk.isEmpty {
            readable.readabilityHandler = nil
            if eof.claim() { onEOF() }
        } else {
            onChunk(chunk)
        }
    }
}

/// 비동기 프로세스 실행기.
/* 변경 전 정책: stdout/stderr를 FileHandle.bytes(AsyncBytes)로 Swift 협조 스레드 풀에서 읽었다.
   실측 결함: 장기 실행 스트림(adb track-devices 같은 StreamingProcess)이 단 1개만 떠 있어도
   이후 모든 run()이 영원히 멈췄다(재현: K=0 → 0.04s, K≥1 → 무응답, 타임아웃도 미발화).
   앱은 항상 track-devices를 띄우므로 connect/pair/자동발견/기기정보 조회가 전부 멈출 수 있었다.
   변경 후 정책: 협조 풀을 전혀 쓰지 않는다 — GCD readabilityHandler로 두 파이프를 소비하고,
   종료는 terminationHandler로 받는다. 대기는 GCD 스레드에서만 한다.
   타임아웃: SIGTERM → 2초 뒤에도 살아 있으면 SIGKILL. 종료 후 남은 출력은 최대 2초만
   회수한다(손자 프로세스가 파이프를 물고 있어도 호출이 묶이지 않게).
   영향 범위: ADB/AppCatalog/CLI 등 ProcessRunner·StreamingProcess를 쓰는 모든 경로. */
enum ProcessRunner {

    static func run(
        _ executable: URL,
        arguments: [String],
        environment: [String: String]? = nil,
        priority: TaskPriority = .utility,
        timeout: TimeInterval = 30
    ) async throws -> ProcessResult {
        let raw = try await runOnGCD(executable, arguments, environment, timeout)
        return ProcessResult(
            status: raw.status,
            stdout: String(data: raw.out, encoding: .utf8) ?? "",
            stderr: String(data: raw.err, encoding: .utf8) ?? ""
        )
    }

    static func runData(
        _ executable: URL,
        arguments: [String],
        environment: [String: String]? = nil,
        timeout: TimeInterval = 30
    ) async throws -> Data {
        try await runOnGCD(executable, arguments, environment, timeout).out
    }

    private struct RawResult: Sendable {
        let status: Int32
        let out: Data
        let err: Data
    }

    private static func runOnGCD(
        _ executable: URL,
        _ arguments: [String],
        _ environment: [String: String]?,
        _ timeout: TimeInterval
    ) async throws -> RawResult {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                continuation.resume(with: Result {
                    try runBlocking(executable, arguments, environment, timeout)
                })
            }
        }
    }

    /// GCD 스레드 전용 — 협조 스레드에서 호출하지 말 것.
    private static func runBlocking(
        _ executable: URL,
        _ arguments: [String],
        _ environment: [String: String]?,
        _ timeout: TimeInterval
    ) throws -> RawResult {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.environment = environment ?? ProcessInfo.processInfo.environment
        process.standardInput = FileHandle.nullDevice
        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe

        let out = LockedBuffer()
        let err = LockedBuffer()
        let pipesClosed = DispatchGroup()
        pipesClosed.enter()
        pipesClosed.enter()
        let exited = DispatchSemaphore(value: 0)

        let outHandle = outPipe.fileHandleForReading
        let errHandle = errPipe.fileHandleForReading
        drainPipe(outHandle, onChunk: { out.append($0) }, onEOF: { pipesClosed.leave() })
        drainPipe(errHandle, onChunk: { err.append($0) }, onEOF: { pipesClosed.leave() })
        process.terminationHandler = { _ in exited.signal() }

        do {
            try process.run()
        } catch {
            outHandle.readabilityHandler = nil
            errHandle.readabilityHandler = nil
            throw ProcessError.launchFailed("\(executable.lastPathComponent): \(error.localizedDescription)")
        }

        var timedOut = false
        if exited.wait(timeout: .now() + timeout) == .timedOut {
            timedOut = true
            let pid = process.processIdentifier
            process.terminate()
            if exited.wait(timeout: .now() + 2) == .timedOut {
                kill(pid, SIGKILL)
                _ = exited.wait(timeout: .now() + 2)
            }
        }
        // 종료 후 파이프 잔여 출력 회수 — 손자 프로세스가 fd를 물고 있어도 최대 2초만 기다린다
        _ = pipesClosed.wait(timeout: .now() + 2)
        outHandle.readabilityHandler = nil
        errHandle.readabilityHandler = nil

        if timedOut {
            throw ProcessError.timedOut(executable.lastPathComponent, seconds: Int(timeout))
        }
        return RawResult(status: process.terminationStatus, out: out.value, err: err.value)
    }
}

/// 개행 단위 분할기(GCD 콜백 간 공유).
private final class LineSplitter: @unchecked Sendable {
    private let lock = NSLock()
    private var pending = Data()

    func feed(_ chunk: Data, _ emit: (String) -> Void) {
        lock.lock()
        pending.append(chunk)
        var lines: [String] = []
        while let newline = pending.firstIndex(of: 0x0A) {
            let lineData = pending.subdata(in: pending.startIndex..<newline)
            pending.removeSubrange(pending.startIndex...newline)
            lines.append(String(data: lineData, encoding: .utf8) ?? "")
        }
        lock.unlock()
        lines.forEach(emit)
    }

    func flush(_ emit: (String) -> Void) {
        lock.lock()
        let rest = pending
        pending.removeAll()
        lock.unlock()
        if !rest.isEmpty { emit(String(data: rest, encoding: .utf8) ?? "") }
    }
}

/// 장기 실행 프로세스(adb track-devices, scrcpy 등) 래퍼.
/// 라인 스트리밍 + 원시 바이트 스트리밍 + 종료 감지 콜백 + stderr 꼬리 캡처 제공.
/* 정책: ProcessRunner와 같은 이유로 협조 스레드 풀(AsyncBytes)을 쓰지 않는다 — GCD
   readabilityHandler + terminationHandler. 종료 통지(onExit)는 stdout EOF가 아니라 프로세스
   종료에 묶는다(EOF는 최대 1초만 기다림) — 손자 프로세스가 stdout을 물고 있어도 세션 정리와
   감시 재시작이 반드시 일어나게. terminate()는 SIGTERM 후 2초 뒤 SIGKILL로 확실히 끝낸다. */
final class StreamingProcess: @unchecked Sendable {
    private let process = Process()
    private let lock = NSLock()
    private var terminated = false

    // stderr 마지막 2KB — 프로세스가 조기 사망했을 때 원인을 사용자에게 보여 주기 위함.
    private let errTail = LockedBuffer(tailLimit: 2048)

    /// 캡처된 stderr 마지막 부분(실패 진단용).
    var stderrTail: String {
        String(data: errTail.value, encoding: .utf8) ?? ""
    }

    /// 프로세스가 아직 살아 있는지(조기 사망 감지용 폴링).
    var isRunning: Bool { process.isRunning }

    private var isTerminated: Bool {
        lock.lock()
        defer { lock.unlock() }
        return terminated
    }

    /// stdout을 한 줄씩 전달(개행 제거).
    func start(
        executable: URL,
        arguments: [String],
        environment: [String: String]? = nil,
        onLine: (@Sendable (String) -> Void)? = nil,
        onExit: (@Sendable (Int32) -> Void)? = nil
    ) throws {
        var chunkHandler: (@Sendable (Data) -> Void)?
        var eofHandler: (@Sendable () -> Void)?
        if let onLine {
            let splitter = LineSplitter()
            chunkHandler = { chunk in splitter.feed(chunk, onLine) }
            eofHandler = { splitter.flush(onLine) }
        }
        try launch(executable, arguments, environment,
                   onChunk: chunkHandler, onStdoutEOF: eofHandler, onExit: onExit)
    }

    /// stdout을 1바이트씩 전달 — 길이 프리픽스 같은 바이너리 프로토콜 파싱용.
    func startByteStream(
        executable: URL,
        arguments: [String],
        environment: [String: String]? = nil,
        onByte: @escaping @Sendable (UInt8) -> Void,
        onExit: (@Sendable (Int32) -> Void)? = nil
    ) throws {
        try launch(
            executable, arguments, environment,
            onChunk: { chunk in chunk.forEach(onByte) },
            onStdoutEOF: nil,
            onExit: onExit
        )
    }

    private func launch(
        _ executable: URL,
        _ arguments: [String],
        _ environment: [String: String]?,
        onChunk: (@Sendable (Data) -> Void)?,
        onStdoutEOF: (@Sendable () -> Void)?,
        onExit: (@Sendable (Int32) -> Void)?
    ) throws {
        process.executableURL = executable
        process.arguments = arguments
        process.environment = environment ?? ProcessInfo.processInfo.environment
        process.standardInput = FileHandle.nullDevice
        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe

        let outHandle = outPipe.fileHandleForReading
        let errHandle = errPipe.fileHandleForReading
        let stdoutClosed = DispatchSemaphore(value: 0)
        let tail = errTail

        drainPipe(outHandle, onChunk: { [weak self] chunk in
            guard let self, !self.isTerminated else { return }
            onChunk?(chunk)
        }, onEOF: {
            onStdoutEOF?()
            stdoutClosed.signal()
        })
        drainPipe(errHandle, onChunk: { tail.append($0) }, onEOF: {})

        process.terminationHandler = { finished in
            let status = finished.terminationStatus
            DispatchQueue.global(qos: .utility).async {
                _ = stdoutClosed.wait(timeout: .now() + 1)
                outHandle.readabilityHandler = nil
                errHandle.readabilityHandler = nil
                onExit?(status)
            }
        }

        do {
            try process.run()
        } catch {
            outHandle.readabilityHandler = nil
            errHandle.readabilityHandler = nil
            throw error
        }
    }

    func terminate() {
        lock.lock()
        terminated = true
        lock.unlock()
        guard process.isRunning else { return }
        let pid = process.processIdentifier
        process.terminate()
        // SIGTERM을 무시하면 2초 뒤 SIGKILL — 창/감시가 안 닫히는 사고 방지
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 2) { [weak self] in
            if self?.process.isRunning == true { kill(pid, SIGKILL) }
        }
    }
}
