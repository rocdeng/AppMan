import Foundation

public struct InstallSourceResolver: Sendable {
    private let homebrewDetector: any HomebrewDetecting
    private let macAppStoreDetector: any MacAppStoreDetecting
    private let sparkleFeedDetector: any SparkleFeedDetecting

    public init(
        homebrewDetector: any HomebrewDetecting = HomebrewCaskDetector(),
        macAppStoreDetector: any MacAppStoreDetecting = MacAppStoreDetector(),
        sparkleFeedDetector: any SparkleFeedDetecting = SparkleFeedDetector()
    ) {
        self.homebrewDetector = homebrewDetector
        self.macAppStoreDetector = macAppStoreDetector
        self.sparkleFeedDetector = sparkleFeedDetector
    }

    public func resolveInstallSource(for app: AppRecord) throws -> InstallSource {
        if let homebrewSource = try homebrewDetector.detectInstallSource(for: app) {
            return homebrewSource
        }

        if macAppStoreDetector.isAppStoreApp(app) {
            return .macAppStore
        }

        if let feedURL = try sparkleFeedDetector.detectFeedURL(for: app) {
            return .sparkle(feedURL: feedURL)
        }

        return .manual(reason: "没有找到 Homebrew Cask、Mac App Store 或 Sparkle 更新源证据")
    }

    public func resolveInstallSources(for apps: [AppRecord]) throws -> [AppRecord] {
        try apps.map { app in
            var resolvedApp = app
            resolvedApp.installSource = try resolveInstallSource(for: app)
            return resolvedApp
        }
    }
}
