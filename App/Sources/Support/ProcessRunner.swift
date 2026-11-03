import Foundation

struct ProcessResult: Sendable {
    let status: Int32
    let stdout: String
    let stderr: String

    var output: String { stdout + stderr }

    var succeeded: Bool { status == 0 }
}

enum ProcessError: Error, LocalizedError {
    case launchFailed(String)

    var errorDescription: String? {
        if case .launchFailed(let message) = self { return message }
        return nil
    }
}

/// 비동기 프로세스 실행기.
/// 정책: stdout/stderr를 FileHandle.bytes(비동기 시퀀스)로 동시에 소비한다.
///   파이프 버퍼(64KB)가 찬 채 한쪽만 동기 읽기하면 교착이 생기는 고전적 함 때문에,
///   블로킹 read를 협조 스레드 풀에서 쓰지 않는다.
enum ProcessRunner {

    static func run(
        _ executable: URL,
        arguments: [String],
        environment: [String: String]? = nil,
        priority: TaskPriority = .utility
    ) async throws -> ProcessResult {
        try await Task.detached(priority: priority) {
            let process = Process()
            process.executableURL = executable
            process.arguments = arguments
            process.environment = environment ?? ProcessInfo.processInfo.environment
            let outPipe = Pipe()
            let errPipe = Pipe()
            process.standardOutput = outPipe
            process.standardError = errPipe
            do { try process.run() } catch {
                throw ProcessError.launchFailed("\(executable.lastPathComponent): \(error.localizedDescription)")
            }
            // 두 파이프를 동시에 소비 후 종료 대기
            async let out = readAll(outPipe.fileHandleForReading)
            async let err = readAll(errPipe.fileHandleForReading)
            let (outData, errData) = try await (out, err)
            process.waitUntilExit()
            return ProcessResult(
                status: process.terminationStatus,
                stdout: String(data: outData, encoding: .utf8) ?? "",
                stderr: String(data: errData, encoding: .utf8) ?? ""
            )
        }.value
    }

    static func runData(
        _ executable: URL,
        arguments: [String],
        environment: [String: String]? = nil
    ) async throws -> Data {
        try await Task.detached(priority: .utility) {
            let process = Process()
            process.executableURL = executable
            process.arguments = arguments
            process.environment = environment ?? ProcessInfo.processInfo.environment
            let outPipe = Pipe()
            process.standardOutput = outPipe
            process.standardError = Pipe()
            do { try process.run() } catch {
                throw ProcessError.launchFailed("\(executable.lastPathComponent): \(error.localizedDescription)")
            }
            let data = try await readAll(outPipe.fileHandleForReading)
            process.waitUntilExit()
            return data
        }.value
    }

    private static func readAll(_ handle: FileHandle) async throws -> Data {
        var data = Data()
        for try await byte in handle.bytes {
            data.append(byte)
        }
        return data
    }
}

/// 장기 실행 프로세스(adb track-devices, scrcpy 등) 래퍼.
/// 라인 스트리밍 + 원시 바이트 스트리밍 + 종료 감지 콜백 제공.
final class StreamingProcess: @unchecked Sendable {
    private let process = Process()
    private let queue = DispatchQueue(label: "macdroid.streaming-process")
    private var terminated = false

    /// stdout을 한 줄씩 전달(개행 제거).
    func start(
        executable: URL,
        arguments: [String],
        environment: [String: String]? = nil,
        onLine: (@Sendable (String) -> Void)? = nil,
        onExit: (@Sendable (Int32) -> Void)? = nil
    ) throws {
        process.executableURL = executable
        process.arguments = arguments
        process.environment = environment ?? ProcessInfo.processInfo.environment
        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe
        try process.run()

        // stderr는 항상 소비 — 두고 않으면 파이프가 차서 자식이 막힌다.
        Task.detached(priority: .utility) {
            for try await _ in errPipe.fileHandleForReading.bytes {}
        }

        let stdout = outPipe.fileHandleForReading
        if let onLine {
            Task.detached(priority: .utility) { [weak self] in
                for try await line in stdout.bytes.lines {
                    guard let self, !self.isTerminated else { break }
                    onLine(String(line))
                }
                guard let self else { return }
                self.process.waitUntilExit()
                onExit?(self.process.terminationStatus)
            }
        } else {
            Task.detached(priority: .utility) { [weak self] in
                for try await _ in stdout.bytes {}
                guard let self else { return }
                self.process.waitUntilExit()
                onExit?(self.process.terminationStatus)
            }
        }
    }

    /// stdout을 1바이트씩 전달 — 길이 프리픽스 같은 바이너리 프로토콜 파싱용.
    func startByteStream(
        executable: URL,
        arguments: [String],
        environment: [String: String]? = nil,
        onByte: @escaping @Sendable (UInt8) -> Void,
        onExit: (@Sendable (Int32) -> Void)? = nil
    ) throws {
        process.executableURL = executable
        process.arguments = arguments
        process.environment = environment ?? ProcessInfo.processInfo.environment
        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe
        try process.run()

        Task.detached(priority: .utility) {
            for try await _ in errPipe.fileHandleForReading.bytes {}
        }

        let stdout = outPipe.fileHandleForReading
        Task.detached(priority: .utility) { [weak self] in
            for try await byte in stdout.bytes {
                guard let self, !self.isTerminated else { break }
                onByte(byte)
            }
            guard let self else { return }
            self.process.waitUntilExit()
            onExit?(self.process.terminationStatus)
        }
    }

    private var isTerminated: Bool {
        queue.sync { terminated }
    }

    func terminate() {
        queue.sync { terminated = true }
        if process.isRunning {
            process.terminate()
        }
    }
}
