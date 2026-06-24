import Foundation

public struct AppRecord: Identifiable, Equatable, Sendable {
    public let id: String
    public let name: String
    public let bundleIdentifier: String?
    public let shortVersion: String?
    public let buildVersion: String?
    public let path: URL
    public let sizeBytes: Int64
    public var installSource: InstallSource

    public init(
        id: String,
        name: String,
        bundleIdentifier: String?,
        shortVersion: String?,
        buildVersion: String?,
        path: URL,
        sizeBytes: Int64,
        installSource: InstallSource = .manual(reason: "尚未识别到安装渠道")
    ) {
        self.id = id
        self.name = name
        self.bundleIdentifier = bundleIdentifier
        self.shortVersion = shortVersion
        self.buildVersion = buildVersion
        self.path = path
        self.sizeBytes = sizeBytes
        self.installSource = installSource
    }
}

public enum InstallSource: Equatable, Sendable {
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
