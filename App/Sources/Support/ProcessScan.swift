import Foundation
import Darwin

/// 프로세스 테이블 스캔(GCD 스레드 동기 실행 전용).
/* 정책: ProcessRunner(비동기 협조 풀)로 /bin/ps를 띄우면 앱 시작 시점에 아무 이유 없이
   영원히 묶이는 사례를 실측했다(타임아웃 킬러까지 발화하지 않음). 원인 추적보다
   증명된 경로를 쓴다 — GCD 스레드에서 동기 Process + readDataToEndOfFile.
   파이프 읽기가 블로킹이지만 일회성 스캔이라 감수 가능하다(실측 0.04s). */
enum ProcessScan {

    struct Entry {
        let pid: Int32
        let ppid: Int32
        let command: String
    }

    /// ps 스냅샷. 실패하면 빈 배열(치명 아님 — 고아 정리는 best-effort).
    static func snapshot() -> [Entry] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["-axo", "pid=,ppid=,command="]
        let outPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = Pipe()
        do { try process.run() } catch { return [] }

        // 동기 읽기 — GCD 스레드에서만 호출할 것
        let data = outPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return [] }

        var entries: [Entry] = []
        for rawLine in String(data: data, encoding: .utf8)?.split(separator: "\n") ?? [] {
            let parts = rawLine.trimmingCharacters(in: .whitespaces)
                .split(separator: " ").map(String.init)
            guard parts.count >= 3, let pid = Int32(parts[0]), let ppid = Int32(parts[1]) else { continue }
            let command = parts.dropFirst(2).joined(separator: " ")
            entries.append(Entry(pid: pid, ppid: ppid, command: command))
        }
        return entries
    }
}
