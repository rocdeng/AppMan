import Foundation

public struct InstallSourceResolver: Sendable {
    private let homebrewDetector: any HomebrewDetecting
    private let macAppStoreDetector: any MacAppStoreDetecting

    public init(
        homebrewDetector: any HomebrewDetecting = HomebrewCaskDetector(),
        macAppStoreDetector: any MacAppStoreDetecting = MacAppStoreDetector()
    ) {
        self.homebrewDetector = homebrewDetector
        self.macAppStoreDetector = macAppStoreDetector
    }

    public func resolveInstallSource(for app: AppRecord) throws -> InstallSource {
        if let homebrewSource = try homebrewDetector.detectInstallSource(for: app) {
            return homebrewSource
        }

        if macAppStoreDetector.isAppStoreApp(app) {
            return .macAppStore
        }

        return .manual(reason: "没有找到 Homebrew Cask 或 Mac App Store 安装证据")
    }

    public func resolveInstallSources(for apps: [AppRecord]) throws -> [AppRecord] {
        try apps.map { app in
            var resolvedApp = app
            resolvedApp.installSource = try resolveInstallSource(for: app)
            return resolvedApp
        }
    }
}
