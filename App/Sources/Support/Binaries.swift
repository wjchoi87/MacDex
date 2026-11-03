import Foundation

/// 번들에 포함된 외부 바이너리(adb/scrcpy/aapt2) 위치 해결.
/// 정책: 항상 번들 내 바이너리만 사용 — 사용자에게 brew/SDK 설치를 요구하지 않는다.
///   (xcodebuild post-build 스크립트가 Vendor → Resources/bin|lib|share 로 복사)
/// 개발 편의용 폴백: 번들에 없으면 프로젝트 Vendor/ 디렉터리를 직접 본다(유닛 실행 디버깅 등).
enum Binaries {

    static var binDir: URL {
        Bundle.main.resourceURL?.appending(path: "bin", directoryHint: .isDirectory)
            ?? URL(fileURLWithPath: "/dev/null")
    }

    static var adb: URL { binDir.appending(path: "adb") }
    static var scrcpy: URL { binDir.appending(path: "scrcpy") }
    static var aapt2: URL { binDir.appending(path: "aapt2") }

    static var scrcpyServer: URL {
        Bundle.main.resourceURL?.appending(path: "share/scrcpy/scrcpy-server")
            ?? URL(fileURLWithPath: "/dev/null/scrcpy-server")
    }

    /// 외부 프로세스에 물려줄 환경. scrcpy가 adb를 찾는 경로와 server jar 위치를 번들로 고정.
    static var processEnvironment: [String: String] {
        var env = ProcessInfo.processInfo.environment
        // 번들 bin을 PATH 최상위로 → scrcpy가 번들 adb를 사용
        env["PATH"] = binDir.path + ":" + (env["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin")
        env["SCRCPY_SERVER_PATH"] = scrcpyServer.path
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
