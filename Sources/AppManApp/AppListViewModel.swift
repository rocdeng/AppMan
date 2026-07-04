import AppManCore
import Foundation

@MainActor
final class AppListViewModel: ObservableObject {
    @Published private(set) var apps: [AppRecord] = []
    @Published private(set) var isScanning = false
    @Published private(set) var isCheckingUpdates = false
    @Published private(set) var isUpdatingApp = false
    @Published private(set) var isUninstalling = false
    @Published private(set) var ignoredApps: [IgnoredAppRecord] = []
    @Published var automaticallyChecksUpdatesOnLaunch = false
    @Published var tinyFishAPIKey = ""
    @Published var errorMessage: String?

    var hasCachedApps: Bool {
        !apps.isEmpty
    }

    private let scanner: AppScanner
    private let installSourceResolver: InstallSourceResolver
    private let injectedUpdateChecker: (any AppUpdateChecking)?
    private let appCache: AppRecordCache
    private let ignoreListStore: UpdateIgnoreListStore
    private let preferencesStore: AppPreferencesStore
    private let selfUpdateSourceStore: SelfUpdateSourceStore
    private let homebrewUpdater: HomebrewCaskUpdater
    private let appBundleReader: AppBundleReader

    init(
        scanner: AppScanner = AppScanner(),
        installSourceResolver: InstallSourceResolver = InstallSourceResolver(),
        updateChecker: (any AppUpdateChecking)? = nil,
        appCache: AppRecordCache = AppRecordCache(),
        ignoreListStore: UpdateIgnoreListStore = UpdateIgnoreListStore(),
        preferencesStore: AppPreferencesStore = AppPreferencesStore(),
        selfUpdateSourceStore: SelfUpdateSourceStore = SelfUpdateSourceStore(),
        homebrewUpdater: HomebrewCaskUpdater = HomebrewCaskUpdater(),
        appBundleReader: AppBundleReader = AppBundleReader()
    ) {
        self.scanner = scanner
        self.installSourceResolver = installSourceResolver
        self.injectedUpdateChecker = updateChecker
        self.appCache = appCache
        self.ignoreListStore = ignoreListStore
        self.preferencesStore = preferencesStore
        self.selfUpdateSourceStore = selfUpdateSourceStore
        self.homebrewUpdater = homebrewUpdater
        self.appBundleReader = appBundleReader
        ignoredApps = (try? ignoreListStore.load()) ?? []
        let preferences = (try? preferencesStore.load()) ?? AppPreferences()
        automaticallyChecksUpdatesOnLaunch = preferences.automaticallyChecksUpdatesOnLaunch
        tinyFishAPIKey = preferences.tinyFishAPIKey
        apps = Self.markIgnored((try? appCache.load()) ?? [], ignoredApps: ignoredApps)
    }

    func scan() async {
        guard !isScanning else {
            return
        }

        isScanning = true
        errorMessage = nil

        do {
            let scanner = self.scanner
            let installSourceResolver = self.installSourceResolver
            let appCache = self.appCache
            let ignoreListStore = self.ignoreListStore
            let resolvedApps = try await Task.detached(priority: .userInitiated) {
                let apps = try scanner.scanInstalledApps()
                let ignoredApps = try ignoreListStore.load()
                let resolvedApps = Self.markIgnored(
                    try installSourceResolver.resolveInstallSources(for: apps),
                    ignoredApps: ignoredApps
                )
                try appCache.save(resolvedApps)
                return resolvedApps
            }.value

            apps = resolvedApps
        } catch {
            errorMessage = error.localizedDescription
        }

        isScanning = false
    }

    func checkUpdates() async {
        await checkUpdates(appsToCheck: nil)
    }

    func checkUpdates(for app: AppRecord) async {
        await checkUpdates(appsToCheck: [app.path])
    }

    private func checkUpdates(appsToCheck appPaths: Set<URL>?) async {
        guard !isCheckingUpdates else {
            return
        }

        isCheckingUpdates = true
        errorMessage = nil

        do {
            let updateChecker = makeUpdateChecker()
            let appCache = self.appCache
            let appBundleReader = self.appBundleReader
            let ignoredAppPaths = Set(ignoredApps.map(\.path))
            let currentApps = apps
            let updatedApps = try await Task.detached(priority: .userInitiated) {
                let refreshedApps = currentApps.map { app in
                    (try? appBundleReader.refreshMetadata(for: app)) ?? app
                }
                let checkableApps = refreshedApps.filter { app in
                    !ignoredAppPaths.contains(app.path) && (appPaths == nil || appPaths?.contains(app.path) == true)
                }
                let checkedApps = try updateChecker.checkUpdates(for: checkableApps)
                var checkedAppIndex = checkedApps.startIndex
                let updatedApps = refreshedApps.map { app in
                    if ignoredAppPaths.contains(app.path) {
                        var ignoredApp = app
                        ignoredApp.updateStatus = .ignored
                        return ignoredApp
                    }

                    guard appPaths == nil || appPaths?.contains(app.path) == true else {
                        return app
                    }

                    guard checkedAppIndex < checkedApps.endIndex else {
                        return app
                    }

                    let checkedApp = checkedApps[checkedAppIndex]
                    checkedAppIndex = checkedApps.index(after: checkedAppIndex)
                    return checkedApp
                }
                try appCache.save(updatedApps)
                return updatedApps
            }.value

            apps = updatedApps
        } catch {
            errorMessage = error.localizedDescription
        }

        isCheckingUpdates = false
    }

    func ignoreUpdates(for app: AppRecord) {
        do {
            var records = try ignoreListStore.load()
            let ignoredApp = IgnoredAppRecord(app: app)
            records.removeAll { $0.path == ignoredApp.path }
            records.append(ignoredApp)
            records.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            try ignoreListStore.save(records)

            ignoredApps = records
            apps = Self.markIgnored(apps, ignoredApps: records)
            try appCache.save(apps)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func removeIgnoredApp(path: URL) {
        do {
            ignoredApps = try ignoreListStore.remove(path: path)
            apps = apps.map { app in
                guard app.path == path else {
                    return app
                }
                var restoredApp = app
                restoredApp.updateStatus = .notChecked
                return restoredApp
            }
            try appCache.save(apps)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func setAutomaticallyChecksUpdatesOnLaunch(_ value: Bool) {
        automaticallyChecksUpdatesOnLaunch = value
        savePreferences()
    }

    func setTinyFishAPIKey(_ value: String) {
        tinyFishAPIKey = value.trimmingCharacters(in: .whitespacesAndNewlines)
        savePreferences()
    }

    private func savePreferences() {
        do {
            try preferencesStore.save(AppPreferences(
                automaticallyChecksUpdatesOnLaunch: automaticallyChecksUpdatesOnLaunch,
                tinyFishAPIKey: tinyFishAPIKey
            ))
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func makeUpdateChecker() -> any AppUpdateChecking {
        if let injectedUpdateChecker {
            return injectedUpdateChecker
        }

        return CompositeAppUpdateChecker(selfHostedChecker: SelfHostedUpdateChecker(
            googleSearcher: PreferredSelfUpdateSearcher(tinyFishAPIKey: tinyFishAPIKey)
        ))
    }

    func saveSelfUpdateURL(_ updateURL: URL, for app: AppRecord) async {
        guard !isCheckingUpdates else {
            return
        }

        isCheckingUpdates = true
        errorMessage = nil

        do {
            let sourceStore = selfUpdateSourceStore
            let appCache = self.appCache
            let currentApps = apps
            let updatedApps = try await Task.detached(priority: .userInitiated) {
                try sourceStore.save(SelfUpdateSourceRecord(app: app, updateURL: updateURL))
                let checker = SelfHostedUpdateChecker(sourceStore: sourceStore)
                let checkedApp = try checker.checkUpdates(for: [app]).first ?? app
                let updatedApps = currentApps.map { existingApp in
                    existingApp.path == app.path ? checkedApp : existingApp
                }
                try appCache.save(updatedApps)
                return updatedApps
            }.value

            apps = updatedApps
        } catch {
            errorMessage = error.localizedDescription
        }

        isCheckingUpdates = false
    }

    func uninstall(_ app: AppRecord, candidates: [UninstallCandidate]) async -> Bool {
        guard !isScanning, !isCheckingUpdates, !isUpdatingApp, !isUninstalling else {
            return false
        }

        isUninstalling = true
        errorMessage = nil

        do {
            let appCache = self.appCache
            let currentApps = apps
            let updatedApps = currentApps.filter { $0.id != app.id }
            try await Task.detached(priority: .userInitiated) {
                for candidate in candidates {
                    var resultingURL: NSURL?
                    try FileManager.default.trashItem(at: candidate.url, resultingItemURL: &resultingURL)
                }
                try appCache.save(updatedApps)
            }.value

            apps = updatedApps
            isUninstalling = false
            return true
        } catch {
            errorMessage = error.localizedDescription
        }

        isUninstalling = false
        return false
    }

    func update(_ app: AppRecord, openURL: @MainActor @escaping (URL) -> Void) async {
        guard !isScanning, !isCheckingUpdates, !isUpdatingApp, !isUninstalling else {
            return
        }

        await updateApp(app, openURL: openURL, refreshAfterHomebrewUpdate: true)
    }

    func updateAll(openURL: @MainActor @escaping (URL) -> Void) async {
        guard !isScanning, !isCheckingUpdates, !isUpdatingApp, !isUninstalling else {
            return
        }

        let appsToUpdate = apps.filter { app in
            switch app.updateStatus {
            case .updateAvailable:
                return true
            default:
                return false
            }
        }

        guard !appsToUpdate.isEmpty else {
            return
        }

        var didUpdateHomebrewCask = false
        for app in appsToUpdate {
            let didUpdate = await updateApp(app, openURL: openURL, refreshAfterHomebrewUpdate: false)
            didUpdateHomebrewCask = didUpdateHomebrewCask || didUpdate
        }

        if didUpdateHomebrewCask {
            await checkUpdates()
        }
    }

    @discardableResult
    private func updateApp(
        _ app: AppRecord,
        openURL: @MainActor @escaping (URL) -> Void,
        refreshAfterHomebrewUpdate: Bool
    ) async -> Bool {
        switch app.installSource {
        case let .homebrewCask(token):
            return await updateHomebrewCask(token: token, refreshAfterUpdate: refreshAfterHomebrewUpdate)
        case .macAppStore, .manual, .sparkle:
            guard let updateURL = app.updateURL else {
                errorMessage = "缺少更新地址"
                return false
            }
            openURL(updateURL)
            return false
        }
    }

    private func updateHomebrewCask(token: String, refreshAfterUpdate: Bool) async -> Bool {
        isUpdatingApp = true
        errorMessage = nil
        var didUpdate = false

        do {
            let updater = homebrewUpdater
            try await Task.detached(priority: .userInitiated) {
                try updater.update(token: token)
            }.value
            didUpdate = true
            if refreshAfterUpdate {
                await checkUpdates()
            }
        } catch CommandError.executableNotFound("brew") {
            errorMessage = "Homebrew 不可用"
        } catch CommandError.failed(_, let stderr) {
            let message = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            errorMessage = message.isEmpty ? "Homebrew 更新失败" : message
        } catch {
            errorMessage = error.localizedDescription
        }

        isUpdatingApp = false
        return didUpdate
    }

    nonisolated private static func markIgnored(_ apps: [AppRecord], ignoredApps: [IgnoredAppRecord]) -> [AppRecord] {
        let ignoredAppPaths = Set(ignoredApps.map(\.path))
        return apps.map { app in
            guard ignoredAppPaths.contains(app.path) else {
                return app
            }

            var ignoredApp = app
            ignoredApp.updateStatus = .ignored
            return ignoredApp
        }
    }
}
