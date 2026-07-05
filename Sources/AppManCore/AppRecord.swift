import Foundation

public struct AppRecord: Identifiable, Equatable, Sendable, Codable {
    public let id: String
    public let name: String
    public let bundleIdentifier: String?
    public let shortVersion: String?
    public let buildVersion: String?
    public let path: URL
    public let sizeBytes: Int64
    public var installSource: InstallSource
    public var updateStatus: AppUpdateStatus
    public var updateURL: URL?
    public var updateURLIsDirectDownload: Bool

    public init(
        id: String,
        name: String,
        bundleIdentifier: String?,
        shortVersion: String?,
        buildVersion: String?,
        path: URL,
        sizeBytes: Int64,
        installSource: InstallSource = .manual(reason: "尚未识别到安装渠道"),
        updateStatus: AppUpdateStatus = .notChecked,
        updateURL: URL? = nil,
        updateURLIsDirectDownload: Bool = false
    ) {
        self.id = id
        self.name = name
        self.bundleIdentifier = bundleIdentifier
        self.shortVersion = shortVersion
        self.buildVersion = buildVersion
        self.path = path
        self.sizeBytes = sizeBytes
        self.installSource = installSource
        self.updateStatus = updateStatus
        self.updateURL = updateURL
        self.updateURLIsDirectDownload = updateURLIsDirectDownload
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case name
        case bundleIdentifier
        case shortVersion
        case buildVersion
        case path
        case sizeBytes
        case installSource
        case updateStatus
        case updateURL
        case updateURLIsDirectDownload
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        bundleIdentifier = try container.decodeIfPresent(String.self, forKey: .bundleIdentifier)
        shortVersion = try container.decodeIfPresent(String.self, forKey: .shortVersion)
        buildVersion = try container.decodeIfPresent(String.self, forKey: .buildVersion)
        path = try container.decode(URL.self, forKey: .path)
        sizeBytes = try container.decode(Int64.self, forKey: .sizeBytes)
        installSource = try container.decode(InstallSource.self, forKey: .installSource)
        updateStatus = try container.decode(AppUpdateStatus.self, forKey: .updateStatus)
        updateURL = try container.decodeIfPresent(URL.self, forKey: .updateURL)
        updateURLIsDirectDownload = try container.decodeIfPresent(Bool.self, forKey: .updateURLIsDirectDownload) ?? false
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encodeIfPresent(bundleIdentifier, forKey: .bundleIdentifier)
        try container.encodeIfPresent(shortVersion, forKey: .shortVersion)
        try container.encodeIfPresent(buildVersion, forKey: .buildVersion)
        try container.encode(path, forKey: .path)
        try container.encode(sizeBytes, forKey: .sizeBytes)
        try container.encode(installSource, forKey: .installSource)
        try container.encode(updateStatus, forKey: .updateStatus)
        try container.encodeIfPresent(updateURL, forKey: .updateURL)
        try container.encode(updateURLIsDirectDownload, forKey: .updateURLIsDirectDownload)
    }
}

public enum AppUpdateStatus: Equatable, Sendable, Codable {
    case notChecked
    case upToDate
    case updateAvailable(installedVersion: String?, latestVersion: String)
    case ignored
    case needsOfficialWebsiteConfirmation(candidateURL: URL)
    case needsManualUpdateURL
    case undetectable
    case unsupported(reason: String)
    case checkFailed(message: String)

    public var displayText: String {
        switch self {
        case .notChecked:
            return "未检查"
        case .upToDate:
            return "最新"
        case let .updateAvailable(_, latestVersion):
            return "可更新到 \(latestVersion)"
        case .ignored:
            return "已忽略"
        case .needsOfficialWebsiteConfirmation:
            return "待确认"
        case .needsManualUpdateURL:
            return "手动输入"
        case .undetectable:
            return "无法检测"
        case .unsupported:
            return "暂不支持检查"
        case .checkFailed:
            return "检查失败"
        }
    }
}

public enum InstallSource: Equatable, Sendable, Codable {
    case homebrewCask(token: String)
    case macAppStore
    case sparkle(feedURL: URL)
    case manual(reason: String)

    public var displayName: String {
        switch self {
        case .homebrewCask:
            return "Homebrew Cask"
        case .macAppStore:
            return "Mac App Store"
        case .sparkle:
            return "Sparkle"
        case .manual:
            return "手动/未知"
        }
    }
}
