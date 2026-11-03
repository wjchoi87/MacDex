import Foundation

// MARK: - Device

struct Device: Identifiable, Equatable, Sendable, Hashable {
    let serial: String
    var state: DeviceState

    // 상세(비동기 채움)
    var model: String?
    var brand: String?
    var manufacturer: String?
    var androidVersion: String?
    var sdkInt: Int?
    var batteryLevel: Int?
    var isCharging: Bool?
    var screenSize: String?

    var id: String { serial }

    var isUSB: Bool { !serial.contains(":") }
    var displayModel: String { model ?? serial }

    var stateBadge: String {
        switch state {
        case .online: return isUSB ? "USB" : "Wi-Fi"
        case .offline: return "오프라인"
        case .unauthorized: return "승인 필요"
        case .unknown: return "인식 안 됨"
        }
    }
}

enum DeviceState: String, Equatable, Sendable {
    case online = "device"
    case offline = "offline"
    case unauthorized = "unauthorized"
    case unknown

    init(rawState: String) {
        switch rawState.trimmingCharacters(in: .whitespaces) {
        case "device": self = .online
        case "offline": self = .offline
        case "unauthorized": self = .unauthorized
        default: self = .unknown
        }
    }
}

// MARK: - Android App

struct AndroidApp: Identifiable, Hashable, Sendable {
    let package: String
    let apkPath: String?

    var label: String?
    var iconURL: URL?

    var id: String { package }

    /// aapt2 라벨이 없을 때 쓸 폴백: 마지막 세그먼트를 사람 이름처럼.
    var fallbackLabel: String {
        let last = package.split(separator: ".").last.map(String.init) ?? package
        return last.prefix(1).uppercased() + last.dropFirst()
    }

    var displayLabel: String { label ?? fallbackLabel }

    /// 모노그램 타일 배경색 결정(패키지 해시 기반 고정 팔레트).
    var monogramColorIndex: Int {
        abs(package.hashValue) % 8
    }
}

// MARK: - mDNS 발견 서비스

struct MdnsService: Identifiable, Equatable, Sendable {
    let name: String
    let address: String  // ip:port
    var id: String { name + address }
}

// MARK: - 미러링 설정

/// 화면 품질 프리셋. 사용자가 개별 값을 건드리면 custom으로 전환.
enum QualityPreset: String, CaseIterable, Codable, Sendable, Identifiable {
    case balanced = "balanced"      // 균형(기본)
    case crisp = "crisp"            // 선명
    case lightweight = "lightweight" // 가볍게(무선/저사양)

    var id: String { rawValue }

    var title: String {
        switch self {
        case .balanced: return "균형"
        case .crisp: return "선명"
        case .lightweight: return "가볍게"
        }
    }

    var subtitle: String {
        switch self {
        case .balanced: return "H.264 · 8 Mbps · 최대 1920px"
        case .crisp: return "H.265 · 16 Mbps · 최대 2560px"
        case .lightweight: return "H.264 · 4 Mbps · 최대 1280px · 60fps 제한"
        }
    }

    var values: MirrorSettings.Video {
        switch self {
        case .balanced: return .init(codec: "h264", bitRateMbps: 8, maxSize: 1920, maxFPS: 0)
        case .crisp: return .init(codec: "h265", bitRateMbps: 16, maxSize: 2560, maxFPS: 0)
        case .lightweight: return .init(codec: "h264", bitRateMbps: 4, maxSize: 1280, maxFPS: 60)
        }
    }
}

struct MirrorSettings: Codable, Equatable, Sendable {
    struct Video: Codable, Equatable, Sendable {
        var codec: String        // h264 | h265 | av1
        var bitRateMbps: Int
        var maxSize: Int         // 0 = 제한 없음
        var maxFPS: Int          // 0 = 제한 없음
    }

    struct VirtualDisplay: Codable, Equatable, Sendable {
        var width: Int
        var height: Int
        var density: Int
    }

    var preset: QualityPreset
    var video: Video
    var audioEnabled: Bool = true
    var stayAwake: Bool = true
    var turnScreenOff: Bool = false
    var showTouches: Bool = false
    var advancedInput: Bool = true    // uhid 키보드/마우스(호버·물리키보드 경험)
    var virtualDisplay: VirtualDisplay = .init(width: 1920, height: 1080, density: 240)

    var isCustomVideo: Bool {
        video != preset.values
    }

    static let `default` = MirrorSettings(
        preset: .balanced,
        video: QualityPreset.balanced.values
    )

    // MARK: 저장

    private static let storageKey = "MacDroid.mirrorSettings"

    static func load() -> MirrorSettings {
        guard let data = UserDefaults.standard.data(forKey: storageKey),
              let decoded = try? JSONDecoder().decode(MirrorSettings.self, from: data) else {
            return .default
        }
        return decoded
    }

    func save() {
        if let data = try? JSONEncoder().encode(self) {
            UserDefaults.standard.set(data, forKey: Self.storageKey)
        }
    }
}
