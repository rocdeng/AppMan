import Foundation

public struct CompositeAppUpdateChecker: AppUpdateChecking {
    private let homebrewChecker: any AppUpdateChecking
    private let macAppStoreChecker: any AppUpdateChecking
    private let sparkleChecker: any AppUpdateChecking
    private let selfHostedChecker: any AppUpdateChecking

    public init(
        homebrewChecker: any AppUpdateChecking = HomebrewCaskUpdateChecker(),
        macAppStoreChecker: any AppUpdateChecking = MacAppStoreUpdateChecker(),
        sparkleChecker: any AppUpdateChecking = SparkleAppcastUpdateChecker(),
        selfHostedChecker: any AppUpdateChecking = SelfHostedUpdateChecker()
    ) {
        self.homebrewChecker = homebrewChecker
        self.macAppStoreChecker = macAppStoreChecker
        self.sparkleChecker = sparkleChecker
        self.selfHostedChecker = selfHostedChecker
    }

    public func checkUpdates(for apps: [AppRecord]) throws -> [AppRecord] {
        try checkUpdates(for: apps, onProgress: { _ in })
    }

    public func checkUpdates(
        for apps: [AppRecord],
        onProgress: @escaping @Sendable (AppRecord) -> Void
    ) throws -> [AppRecord] {
        var updatedApps = apps

        try updateApps(
            of: .homebrewCask,
            in: apps,
            checker: homebrewChecker,
            updatedApps: &updatedApps,
            onProgress: onProgress
        )
        try updateApps(
            of: .macAppStore,
            in: apps,
            checker: macAppStoreChecker,
            updatedApps: &updatedApps,
            onProgress: onProgress
        )
        try updateApps(
            of: .sparkle,
            in: apps,
            checker: sparkleChecker,
            updatedApps: &updatedApps,
            onProgress: onProgress
        )
        try updateApps(
            of: .manual,
            in: apps,
            checker: selfHostedChecker,
            updatedApps: &updatedApps,
            onProgress: onProgress
        )

        return updatedApps
    }

    private func updateApps(
        of sourceKind: InstallSourceKind,
        in apps: [AppRecord],
        checker: any AppUpdateChecking,
        updatedApps: inout [AppRecord],
        onProgress: @escaping @Sendable (AppRecord) -> Void
    ) throws {
        let indexedApps = apps.enumerated().filter { _, app in
            app.updateStatus != .ignored && matches(sourceKind, app.installSource)
        }
        let checkedApps = try checker.checkUpdates(for: indexedApps.map(\.element), onProgress: onProgress)

        for (offset, checkedApp) in checkedApps.enumerated() where indexedApps.indices.contains(offset) {
            updatedApps[indexedApps[offset].offset] = checkedApp
        }
    }

    private func matches(_ sourceKind: InstallSourceKind, _ installSource: InstallSource) -> Bool {
        switch (sourceKind, installSource) {
        case (.homebrewCask, .homebrewCask):
            return true
        case (.macAppStore, .macAppStore):
            return true
        case (.sparkle, .sparkle):
            return true
        case (.manual, .manual):
            return true
        default:
            return false
        }
    }
}

private enum InstallSourceKind {
    case homebrewCask
    case macAppStore
    case sparkle
    case manual
}
