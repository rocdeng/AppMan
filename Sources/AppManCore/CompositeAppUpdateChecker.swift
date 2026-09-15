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

        let batches = makeCheckBatches(for: apps)
        let checkedBatches = try LimitedConcurrentMap.map(batches, limit: 3) { batch in
            let checkedApps = try batch.checker.checkUpdates(
                for: batch.indexedApps.map(\.element),
                onProgress: onProgress
            )
            return zip(batch.indexedApps, checkedApps).map { indexedApp, checkedApp in
                (indexedApp.offset, checkedApp)
            }
        }

        for (offset, checkedApp) in checkedBatches.flatMap({ $0 }) {
            updatedApps[offset] = checkedApp
        }

        return updatedApps
    }

    private func makeCheckBatches(for apps: [AppRecord]) -> [UpdateCheckBatch] {
        var batches: [UpdateCheckBatch] = []

        let homebrewApps = indexedApps(of: .homebrewCask, in: apps)
        if !homebrewApps.isEmpty {
            batches.append(UpdateCheckBatch(indexedApps: homebrewApps, checker: homebrewChecker))
        }

        for (sourceKind, checker) in [
            (InstallSourceKind.macAppStore, macAppStoreChecker),
            (.sparkle, sparkleChecker),
            (.manual, selfHostedChecker),
        ] {
            batches.append(contentsOf: indexedApps(of: sourceKind, in: apps).map { indexedApp in
                UpdateCheckBatch(indexedApps: [indexedApp], checker: checker)
            })
        }

        return batches
    }

    private func indexedApps(
        of sourceKind: InstallSourceKind,
        in apps: [AppRecord]
    ) -> [(offset: Int, element: AppRecord)] {
        apps.enumerated().filter { _, app in
            app.updateStatus != .ignored && matches(sourceKind, app.installSource)
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

private struct UpdateCheckBatch: Sendable {
    let indexedApps: [(offset: Int, element: AppRecord)]
    let checker: any AppUpdateChecking
}

private enum InstallSourceKind {
    case homebrewCask
    case macAppStore
    case sparkle
    case manual
}
