import Foundation
import AppKit

/// 설치된 앱의 라벨/아이콘 로더.
/// 정책: aapt2 badging은 APK를 로컬로 받아야 한다. 전체 앱을 한 번에 받으면 수백 MB가
///   소요되므로 → 화면에 보이는 타일만 지연 로딩하고, 결과는 IconCache에 영구 캐시한다.
///   APK가 80MB를 넘으면(대형 게임) 다운로드를 생략하고 모노그램 타일로 유지한다.
enum AppCatalog {

    private static let maxApkBytes = 80 * 1024 * 1024

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
