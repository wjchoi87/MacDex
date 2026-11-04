import Foundation
import AppKit

/// 설치된 앱의 라벨/아이콘 로더.
/// 정책: aapt2 badging은 APK를 로컬로 받아야 한다. 전체 앱을 한 번에 받으면 수백 MB가
///   소요되므로 → 화면에 보이는 타일만 지연 로딩하고, 결과는 IconCache에 영구 캐시한다.
///   APK가 80MB를 넘으면(대형 게임) 다운로드를 생략하고 모노그램 타일로 유지한다.
enum AppCatalog {

    private static let maxApkBytes = 80 * 1024 * 1024
    private static let remoteIndexJar = "/data/local/tmp/macdroid-appindex.jar"

    /// 폰 런처(앱 서랍)와 같은 앱 목록 + 실제 라벨·아이콘 — 기기에서 인덱서(app_process)를 돌려 한 번에 받는다.
    /* 변경 전 정책: `pm list packages -3`(서드파티만) + 보이는 타일마다 APK를 통째로 받아 aapt2로 라벨/아이콘 추출.
         실측: 느리고(APK 다운로드), adaptive/벡터 아이콘 대부분 실패해 모노그램만 보였다. 시스템 앱(카메라·설정 등)은 빠졌다.
       변경 후 정책: 기기 PackageManager로 런처 액티비티 목록을 실제 라벨·렌더링된 아이콘(PNG)과 함께 받는다(282개 ≈ 3초).
         일부 아이콘은 그리는 중 네이티브 abort(Samsung 캘린더 — gDefaultTypeface assert)로 인덱서가 죽는다 →
         마지막 BEGIN 앱부터 이어서(그 앱은 라벨만) 재실행한다(최대 6회).
       영향 범위: 앱 런처·CLI 앱 목록. 인덱서가 없거나 실패하면 nil → 호출부가 기존 방식으로 폴백. */
    static func loadIndex(serial: String, iconSize: Int = 128) async -> [AndroidApp]? {
        let env = Binaries.processEnvironment
        guard FileManager.default.fileExists(atPath: Binaries.appIndexJar.path),
              let pushed = try? await ProcessRunner.run(
                Binaries.adb, arguments: ["-s", serial, "push", Binaries.appIndexJar.path, remoteIndexJar],
                environment: env, timeout: 15),
              pushed.succeeded else { return nil }

        var apps: [String: AndroidApp] = [:]
        var resumeAt: String?
        for _ in 0..<6 {
            var command = "CLASSPATH=\(remoteIndexJar) app_process / kr.macdroid.AppIndex \(iconSize)"
            if let resumeAt { command += " \(resumeAt)" }
            guard let result = try? await ProcessRunner.run(
                Binaries.adb, arguments: ["-s", serial, "shell", command], environment: env, timeout: 90
            ) else { break }

            var unfinished: String?
            for line in result.stdout.split(separator: "\n") {
                let fields = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
                if fields.first == "BEGIN", fields.count >= 2 {
                    unfinished = fields[1]
                } else if fields.first == "APP", fields.count >= 5 {
                    unfinished = nil
                    apps[fields[1]] = storeIndexed(package: fields[1], activity: fields[2],
                                                   label: fields[3], iconBase64: fields[4])
                }
            }
            // 정상 종료(미완료 BEGIN 없음) 또는 같은 앱에서 또 죽으면 끝
            guard let crashed = unfinished, crashed != resumeAt else { break }
            resumeAt = crashed
        }
        guard !apps.isEmpty else { return nil }
        return apps.values.sorted {
            $0.displayLabel.localizedStandardCompare($1.displayLabel) == .orderedAscending
        }
    }

    /// 인덱서 결과를 IconCache(라벨·아이콘)에 저장하고 AndroidApp으로 돌려준다.
    private static func storeIndexed(package: String, activity: String, label: String, iconBase64: String) -> AndroidApp {
        var app = AndroidApp(package: package, apkPath: nil)
        app.activity = activity.isEmpty ? nil : activity
        app.label = label.isEmpty ? nil : label
        let iconFile = Binaries.iconCache.appending(path: package + ".png")
        if let label = app.label {
            try? label.data(using: .utf8)?.write(to: Binaries.iconCache.appending(path: package + ".label"))
        }
        if let data = Data(base64Encoded: iconBase64), !data.isEmpty {
            try? data.write(to: iconFile, options: .atomic)
            app.iconURL = iconFile
        } else if FileManager.default.fileExists(atPath: iconFile.path) {
            app.iconURL = iconFile
        }
        return app
    }

    /// 라벨+아이콘 로드 결과(캐시 포함). 실패/생략 시 nil 유지 → UI 폴백.
    static func loadMetadata(serial: String, app: AndroidApp) async -> AndroidApp {
        var updated = app

        let iconFile = Binaries.iconCache.appending(path: app.package + ".png")
        let labelFile = Binaries.iconCache.appending(path: app.package + ".label")

        // 캐시 hit
        if FileManager.default.fileExists(atPath: iconFile.path) {
            updated.iconURL = iconFile
            updated.label = try? String(contentsOf: labelFile, encoding: .utf8)
            return updated
        }

        guard let apkPath = app.apkPath, !apkPath.isEmpty else { return updated }

        do {
            // APK 크기 확인(대형 APK 생략 정책)
            let sizeOut = try await ADB.shell(serial: serial, "stat -c %s '\(apkPath)'")
            guard let size = Int(sizeOut.trimmingCharacters(in: .whitespacesAndNewlines)),
                  size <= maxApkBytes else { return updated }

            // 임시로 받아서 aapt2 badging
            let tmpDir = FileManager.default.temporaryDirectory
                .appending(path: "macdroid-apk-\(app.package.replacingOccurrences(of: "/", with: "_"))",
                           directoryHint: .isDirectory)
            try? FileManager.default.removeItem(at: tmpDir)
            try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: tmpDir) }

            let localApk = tmpDir.appending(path: "base.apk")
            let pullResult = try await ProcessRunner.run(
                Binaries.adb,
                arguments: ["-s", serial, "pull", apkPath, localApk.path],
                environment: Binaries.processEnvironment
            )
            guard pullResult.succeeded else { return updated }

            let badging = try await ProcessRunner.run(
                Binaries.aapt2,
                arguments: ["dump", "badging", localApk.path],
                environment: Binaries.processEnvironment
            )
            guard badging.succeeded else { return updated }
            let text = badging.stdout

            // 라벨: 현지화(ko) 우선 → 기본
            if let label = firstQuotedValue(in: text, key: "application-label-ko:")
                    ?? firstQuotedValue(in: text, key: "application-label:") {
                updated.label = label
                if let data = label.data(using: .utf8) {
                    try? data.write(to: labelFile)
                }
            }

            // 아이콘: 밀도 숫자가 가장 높은 엔트리.
            // 현대 앱은 모든 밀도가 adaptive XML(mipmap-anydpi-v*)인 경우가 많다.
            // 이때는 xmltree로 foreground 리소스 ID를 찾고, resources 테이블에서
            // 그 파일 경로를 해석해 PNG면 추출한다(실측 80% 커버). 벡터 XML은 모노그램 폴백.
            if let iconPath = highestDensityIconPath(in: text) {
                let resolved: String?
                if iconPath.hasSuffix(".xml") {
                    resolved = await resolveAdaptiveForeground(apk: localApk, iconPath: iconPath)
                } else if iconPath.hasSuffix(".png") {
                    resolved = iconPath
                } else {
                    resolved = nil
                }
                if let pngPath = resolved {
                    let iconData = try await ProcessRunner.runData(
                        URL(fileURLWithPath: "/usr/bin/unzip"),
                        arguments: ["-p", localApk.path, pngPath]
                    )
                    if !iconData.isEmpty, let rep = NSBitmapImageRep(data: iconData),
                       let png = rep.representation(using: .png, properties: [:]) {
                        try? png.write(to: iconFile, options: .atomic)
                        updated.iconURL = iconFile
                    }
                }
            }
        } catch {
            // 메타데이터 로드 실패는 치명 아님 — 폴백 타일 유지
        }
        return updated
    }

    // MARK: badging 파싱

    /// adaptive 아이콘 XML의 foreground 리소스를 PNG 파일 경로로 해석.
    /// 체인: badging(xml) → `dump xmltree --file`(foreground @0xID) → `dump resources`(ID→파일).
    private static func resolveAdaptiveForeground(apk: URL, iconPath: String) async -> String? {
        let env = Binaries.processEnvironment
        guard let tree = try? await ProcessRunner.run(
            Binaries.aapt2,
            arguments: ["dump", "xmltree", "--file", iconPath, apk.path],
            environment: env
        ), tree.succeeded else { return nil }

        // "E: foreground" 다음 줄의 "@0x7f10002c" 추출
        var foregroundID: String?
        let lines = tree.stdout.split(separator: "\n").map(String.init)
        for (index, line) in lines.enumerated() where line.contains("E: foreground") {
            let window = lines[(index + 1)...].prefix(2).joined()
            if let range = window.range(of: "@0x[0-9a-fA-F]+", options: .regularExpression) {
                foregroundID = String(window[range].dropFirst())  // '0x7f10002c'
                break
            }
        }
        guard let id = foregroundID else { return nil }

        guard let table = try? await ProcessRunner.run(
            Binaries.aapt2,
            arguments: ["dump", "resources", apk.path],
            environment: env
        ), table.succeeded else { return nil }

        // "resource 0x7f10002c drawable/foo" 이후 첫 "(file) res/..." 경로
        let tableLines = table.stdout.split(separator: "\n").map(String.init)
        guard let start = tableLines.firstIndex(where: { $0.contains("resource \(id)") }) else { return nil }
        for line in tableLines[(start + 1)...].prefix(12) {
            if line.contains("resource 0x") { break }  // 다음 리소스 시작 → 파일 없음
            if let range = line.range(of: #"\(file\) (res/\S+)"#, options: .regularExpression) {
                let path = String(line[range]).replacingOccurrences(of: "(file) ", with: "")
                return path.hasSuffix(".png") ? path : nil
            }
        }
        return nil
    }

    /// "key:'value'" 형식에서 value 추출.
    private static func firstQuotedValue(in text: String, key: String) -> String? {
        guard let range = text.range(of: key) else { return nil }
        let rest = text[range.upperBound...]
        guard let open = rest.firstIndex(of: "'"), let close = rest[rest.index(after: open)...].firstIndex(of: "'") else {
            return nil
        }
        return String(rest[rest.index(after: open)..<close])
    }

    /// application-icon-<density> 엔트리 중 최대 밀도의 리소스 경로.
    private static func highestDensityIconPath(in text: String) -> String? {
        var best: (density: Int, path: String)?
        for line in text.split(separator: "\n") {
            let t = line.trimmingCharacters(in: .whitespaces)
            guard t.hasPrefix("application-icon-") else { continue }
            // application-icon-640:'res/mipmap-xxx/icon.png'
            let body = t.dropFirst("application-icon-".count)
            guard let colon = body.firstIndex(of: ":") else { continue }
            let density = Int(body[body.startIndex..<colon]) ?? 0
            let quoted = body[body.index(after: colon)...]
            guard let open = quoted.firstIndex(of: "'"),
                  let close = quoted[quoted.index(after: open)...].firstIndex(of: "'") else { continue }
            let path = String(quoted[quoted.index(after: open)..<close])
            if best == nil || density > best!.density {
                best = (density, path)
            }
        }
        return best?.path
    }
}
