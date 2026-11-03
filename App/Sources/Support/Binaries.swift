import Foundation

/// 번들에 포함된 외부 바이너리(adb/scrcpy/aapt2) 위치 해결.
/// 검색 순서(GUI와 CLI가 같은 코드를 공유):
///   1. 실행 파일/앱 번들 옆의 bin/ (post-build 스크립트가 Vendor를 깔아둔다)
///   2. 설치된 MacDroid.app (/Applications, ~/Applications)
///   3. MACDROID_BIN 환경 변수로 지정한 디렉터리
///   4. 시스템 PATH의 일반적인 위치(/opt/homebrew/bin, /usr/local/bin)
/// 정책: 가능한 한 번들 바이너리를 쓴다(사용자에게 brew/SDK 설치를 요구하지 않음).
///   어디서도 발견 못 하면 /usr/bin을 가리키고 실행 시 명확한 에러로 안내한다.
enum Binaries {

    private static let resolvedDir: URL = {
        let candidates: [URL] = [
            // 1) 번들 리소스 바로 옆(GUI 앱: .app/Contents/Resources, CLI: 실행 파일과 같은 디렉터리)
            Bundle.main.resourceURL?.appending(path: "bin", directoryHint: .isDirectory),
            Bundle.main.bundleURL.appending(path: "bin", directoryHint: .isDirectory),
            // 2) 설치된 MacDroid.app
            URL(fileURLWithPath: "/Applications/MacDroid.app/Contents/Resources/bin", isDirectory: true),
            FileManager.default.homeDirectoryForCurrentUser
                .appending(path: "Applications/MacDroid.app/Contents/Resources/bin", directoryHint: .isDirectory),
            // 3) MACDROID_BIN
            ProcessInfo.processInfo.environment["MACDROID_BIN"]
                .map { URL(fileURLWithPath: $0, isDirectory: true) },
        ].compactMap { $0 }

        func hasAdb(_ dir: URL) -> Bool {
            FileManager.default.isExecutableFile(atPath: dir.appending(path: "adb").path)
        }

        for dir in candidates where hasAdb(dir) { return dir }
        // 4) PATH 폴백: 흔한 설치 위치 스캔
        for path in ["/opt/homebrew/bin", "/usr/local/bin"]
        where hasAdb(URL(fileURLWithPath: path, isDirectory: true)) {
            return URL(fileURLWithPath: path, isDirectory: true)
        }
        return URL(fileURLWithPath: "/usr/bin", isDirectory: true)
    }()

    static var binDir: URL { resolvedDir }

    private static let adbFound =
        FileManager.default.isExecutableFile(atPath: resolvedDir.appending(path: "adb").path)

    /// adb를 실제로 찾았는지 — 못 찾으면 안내 에러를 낸다.
    static var adbAvailable: Bool { adbFound }

    static var adb: URL { resolvedDir.appending(path: "adb") }
    static var scrcpy: URL { resolvedDir.appending(path: "scrcpy") }
    static var aapt2: URL { resolvedDir.appending(path: "aapt2") }

    static var scrcpyServer: URL {
        // scrcpy 바이너리 기준 상대 위치: <bin>/../share/scrcpy/scrcpy-server
        resolvedDir.deletingLastPathComponent()
            .appending(path: "share/scrcpy/scrcpy-server")
    }

    /// 외부 프로세스에 물려줄 환경. scrcpy가 adb를 찾는 경로와 server jar 위치를 고정.
    static var processEnvironment: [String: String] {
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = binDir.path + ":" + (env["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin")
        if FileManager.default.fileExists(atPath: scrcpyServer.path) {
            env["SCRCPY_SERVER_PATH"] = scrcpyServer.path
        }
        env["ADB"] = adb.path
        // adb가 사용자 home 기반 key를 찾도록(무선 페어링 키 저장 위치)
        if env["ANDROID_SDK_HOME"] == nil { env["ANDROID_SDK_HOME"] = appSupport.path }
        return env
    }

    static var appSupport: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        let dir = base.appending(path: "MacDroid", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static var iconCache: URL {
        let dir = appSupport.appending(path: "IconCache", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
}
