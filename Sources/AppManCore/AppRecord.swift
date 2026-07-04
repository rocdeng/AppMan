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
        updateURL: URL? = nil
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
