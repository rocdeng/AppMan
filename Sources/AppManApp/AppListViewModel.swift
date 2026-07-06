import AppManCore
import AppKit
import Foundation

struct DownloadProgress: Equatable, Sendable {
    let bytesReceived: Int64
    let totalBytes: Int64?
}

struct AppInfoDetails: Equatable {
    let currentVersion: String
    let latestVersion: String
    let websiteTitle: String
    let websiteURL: URL?
    let latestVersionLinkTitle: String
    let latestVersionURL: URL?

    init(app: AppRecord) {
        currentVersion = app.currentVersionDisplayText
        latestVersion = app.latestVersionDisplayText

        let updateURL = Self.updateURL(for: app)
        let websiteLink = updateURL.flatMap(Self.websiteLink(for:))
        websiteURL = websiteLink?.url
        websiteTitle = websiteLink?.title ?? "暂无"
        latestVersionURL = updateURL
        latestVersionLinkTitle = Self.latestVersionLinkTitle(for: app, hasURL: updateURL != nil)
    }

    private static func updateURL(for app: AppRecord) -> URL? {
        switch app.updateStatus {
        case let .needsOfficialWebsiteConfirmation(candidateURL):
            return candidateURL
        default:
            return app.updateURL
        }
    }

    private static func websiteLink(for url: URL) -> WebsiteLink? {
        guard let scheme = url.scheme,
              let host = url.host(percentEncoded: false) else {
            return nil
        }

        let pathComponents = url.pathComponents.filter { $0 != "/" }
        if host == "github.com", pathComponents.count >= 2 {
            let projectPath = "\(pathComponents[0])/\(pathComponents[1])"
            guard let projectURL = URL(string: "\(scheme)://\(host)/\(projectPath)") else {
                return nil
            }
            return WebsiteLink(title: "\(host)/\(projectPath)", url: projectURL)
        }

        guard let rootURL = URL(string: "\(scheme)://\(host)") else {
            return nil
        }
        return WebsiteLink(title: host, url: rootURL)
    }

    private static func latestVersionLinkTitle(for app: AppRecord, hasURL: Bool) -> String {
        guard hasURL else {
            return "暂无"
        }

        switch app.updateStatus {
        case .needsOfficialWebsiteConfirmation:
            return "候选官网"
        case .needsManualUpdateURL:
            return "需手动输入"
        default:
            return app.updateURLIsDirectDownload ? "下载链接" : "打开链接"
        }
    }
}

private struct WebsiteLink: Equatable {
    let title: String
    let url: URL
}

private final class CheckUpdateProgress: @unchecked Sendable {
    private let lock = NSLock()
    private var completed = 0

    func completeOne() -> Int {
        lock.lock()
        defer { lock.unlock() }
        completed += 1
        return completed
    }
}

@MainActor
final class AppListViewModel: ObservableObject {
    @Published private(set) var apps: [AppRecord] = []
    @Published private(set) var isScanning = false
    @Published private(set) var isCheckingUpdates = false
    @Published private(set) var isUpdatingApp = false
    @Published private(set) var isUninstalling = false
    @Published private(set) var updateProgressText: String?
    @Published private(set) var statusMessage: String?
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
    private let fileManager: FileManager
    private let downloadsDirectory: URL?
    private let downloadData: @Sendable (URL, @escaping @MainActor (DownloadProgress) async -> Void) async throws -> Data
    private let revealDownloadedPackage: @MainActor (URL) -> Void
    private let openDownloadedPackage: @MainActor (URL) -> Void
    private var currentUpdateTask: Task<Bool, Never>?

    init(
        scanner: AppScanner = AppScanner(),
        installSourceResolver: InstallSourceResolver = InstallSourceResolver(),
        updateChecker: (any AppUpdateChecking)? = nil,
        appCache: AppRecordCache = AppRecordCache(),
        ignoreListStore: UpdateIgnoreListStore = UpdateIgnoreListStore(),
        preferencesStore: AppPreferencesStore = AppPreferencesStore(),
        selfUpdateSourceStore: SelfUpdateSourceStore = SelfUpdateSourceStore(),
        homebrewUpdater: HomebrewCaskUpdater = HomebrewCaskUpdater(),
        appBundleReader: AppBundleReader = AppBundleReader(),
        fileManager: FileManager = .default,
        downloadsDirectory: URL? = nil,
        downloadData: @escaping @Sendable (
            URL,
            @escaping @MainActor (DownloadProgress) async -> Void
        ) async throws -> Data = defaultDownloadData,
        revealDownloadedPackage: @escaping @MainActor (URL) -> Void = { url in
            NSWorkspace.shared.activateFileViewerSelecting([url])
        },
        openDownloadedPackage: @escaping @MainActor (URL) -> Void = { url in
            NSWorkspace.shared.open(url)
        }
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
        self.fileManager = fileManager
        self.downloadsDirectory = downloadsDirectory
        self.downloadData = downloadData
        self.revealDownloadedPackage = revealDownloadedPackage
        self.openDownloadedPackage = openDownloadedPackage
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
        updateProgressText = nil

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
                let totalCount = checkableApps.count
                if totalCount > 0 {
                    await MainActor.run {
                        self.updateProgressText = Self.checkUpdateProgressText(completed: 0, total: totalCount)
                    }
                }

                let progress = CheckUpdateProgress()
                let checkedApps = try updateChecker.checkUpdates(for: checkableApps) { _ in
                    let completed = progress.completeOne()
                    Task { @MainActor in
                        self.updateProgressText = Self.checkUpdateProgressText(
                            completed: completed,
                            total: totalCount
                        )
                    }
                }

                var checkedAppsByPath: [URL: AppRecord] = [:]
                for checkedApp in checkedApps {
                    checkedAppsByPath[checkedApp.path] = checkedApp
                }

                let updatedApps = refreshedApps.map { app in
                    if ignoredAppPaths.contains(app.path) {
                        var ignoredApp = app
                        ignoredApp.updateStatus = .ignored
                        return ignoredApp
                    }

                    guard appPaths == nil || appPaths?.contains(app.path) == true else {
                        return app
                    }

                    return checkedAppsByPath[app.path] ?? app
                }
                try appCache.save(updatedApps)
                return updatedApps
            }.value

            apps = updatedApps
        } catch {
            errorMessage = error.localizedDescription
        }

        updateProgressText = nil
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

        currentUpdateTask = Task { @MainActor in
            await updateApp(app, openURL: openURL, refreshAfterHomebrewUpdate: true)
        }
        _ = await currentUpdateTask?.value
        currentUpdateTask = nil
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

    func cancelUpdate() {
        currentUpdateTask?.cancel()
    }

    func clearStatusMessage() {
        statusMessage = nil
    }

    #if DEBUG
    func replaceAppsForTesting(_ apps: [AppRecord]) {
        self.apps = apps
    }
    #endif

    @discardableResult
    private func updateApp(
        _ app: AppRecord,
        openURL: @MainActor @escaping (URL) -> Void,
        refreshAfterHomebrewUpdate: Bool
    ) async -> Bool {
        switch app.installSource {
        case let .homebrewCask(token):
            return await updateHomebrewCask(token: token, refreshAfterUpdate: refreshAfterHomebrewUpdate)
        case .macAppStore:
            guard let updateURL = app.updateURL else {
                errorMessage = "缺少更新地址"
                return false
            }
            openURL(updateURL)
            return false
        case .manual, .sparkle:
            guard let updateURL = app.updateURL else {
                errorMessage = "缺少下载地址"
                return false
            }

            if Self.shouldDownloadPackage(for: app) {
                return await downloadPackage(from: updateURL)
            }

            openURL(updateURL)
            return false
        }
    }

    private func downloadPackage(from url: URL) async -> Bool {
        isUpdatingApp = true
        updateProgressText = "正在准备下载..."
        errorMessage = nil
        var didDownload = false

        do {
            let fileManager = self.fileManager
            let downloadsDirectory = self.downloadsDirectory
            let downloadData = self.downloadData
            let downloadsURL = try await Task.detached(priority: .userInitiated) {
                try Self.appManDownloadsDirectory(fileManager: fileManager, downloadsDirectory: downloadsDirectory)
            }.value
            let existingPackageURL = Self.existingDestinationURL(
                for: url,
                in: downloadsURL,
                fileManager: fileManager
            )
            if let existingPackageURL {
                updateProgressText = "正在打开下载位置..."
                revealDownloadedPackage(existingPackageURL)
                didDownload = true
                updateProgressText = nil
                isUpdatingApp = false
                return didDownload
            }

            updateProgressText = "正在下载安装包..."
            let data = try await downloadData(url) { [weak self] progress in
                self?.updateProgressText = Self.downloadProgressText(for: progress)
            }

            updateProgressText = "正在保存安装包..."
            let destinationURL = try await Task.detached(priority: .userInitiated) {
                let destinationURL = Self.uniqueDestinationURL(
                    for: url,
                    in: downloadsURL,
                    fileManager: fileManager
                )
                try data.write(to: destinationURL, options: [.atomic])
                return destinationURL
            }.value

            updateProgressText = "正在打开安装包..."
            openDownloadedPackage(destinationURL)
            didDownload = true
        } catch where Self.isCancellation(error) {
            statusMessage = "已取消下载"
            didDownload = false
        } catch {
            errorMessage = "下载失败：\(error.localizedDescription)"
        }

        updateProgressText = nil
        isUpdatingApp = false
        return didDownload
    }

    private func updateHomebrewCask(token: String, refreshAfterUpdate: Bool) async -> Bool {
        isUpdatingApp = true
        updateProgressText = "正在通过 Homebrew 更新 \(token)..."
        errorMessage = nil
        var didUpdate = false

        do {
            let updater = homebrewUpdater
            try await Task.detached(priority: .userInitiated) {
                try updater.update(token: token)
            }.value
            didUpdate = true
            if refreshAfterUpdate {
                updateProgressText = "正在刷新更新状态..."
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

        updateProgressText = nil
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

    nonisolated static func shouldDownloadPackage(for app: AppRecord) -> Bool {
        guard let updateURL = app.updateURL else {
            return false
        }
        return app.updateURLIsDirectDownload || isPackageURL(updateURL)
    }

    nonisolated private static func isPackageURL(_ url: URL) -> Bool {
        ["dmg", "pkg", "zip"].contains(url.pathExtension.lowercased())
    }

    nonisolated private static func isCancellation(_ error: Error) -> Bool {
        if error is CancellationError {
            return true
        }

        guard let urlError = error as? URLError else {
            return false
        }
        return urlError.code == .cancelled
    }

    nonisolated private static func appManDownloadsDirectory(
        fileManager: FileManager,
        downloadsDirectory: URL?
    ) throws -> URL {
        let downloadsURL = downloadsDirectory
            ?? fileManager.urls(for: .downloadsDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Downloads", isDirectory: true)
        let appManURL = downloadsURL.appendingPathComponent("AppMan", isDirectory: true)
        try fileManager.createDirectory(at: appManURL, withIntermediateDirectories: true)
        return appManURL
    }

    nonisolated static func downloadProgressText(for progress: DownloadProgress) -> String {
        guard let totalBytes = progress.totalBytes, totalBytes > 0 else {
            return "正在下载安装包...\n已下载 \(formatByteCount(progress.bytesReceived))"
        }

        let percentage = max(0, min(100, Int((Double(progress.bytesReceived) / Double(totalBytes) * 100).rounded())))
        return "正在下载安装包...\n总大小 \(formatByteCount(totalBytes))，已下载 \(formatByteCount(progress.bytesReceived)) (\(percentage)%)"
    }

    nonisolated static func checkUpdateProgressText(completed: Int, total: Int) -> String {
        "正在检查更新... (\(completed)/\(total))"
    }

    nonisolated private static func formatByteCount(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    nonisolated private static func uniqueDestinationURL(
        for sourceURL: URL,
        in directoryURL: URL,
        fileManager: FileManager
    ) -> URL {
        let filename = destinationFilename(for: sourceURL)
        let baseURL = destinationURL(for: sourceURL, in: directoryURL)
        guard fileManager.fileExists(atPath: baseURL.path) else {
            return baseURL
        }

        let extensionName = baseURL.pathExtension
        let stem = extensionName.isEmpty
            ? baseURL.lastPathComponent
            : baseURL.deletingPathExtension().lastPathComponent

        for index in 2...999 {
            let candidateName = extensionName.isEmpty
                ? "\(stem)-\(index)"
                : "\(stem)-\(index).\(extensionName)"
            let candidateURL = directoryURL.appendingPathComponent(candidateName)
            if !fileManager.fileExists(atPath: candidateURL.path) {
                return candidateURL
            }
        }

        return directoryURL.appendingPathComponent("\(UUID().uuidString)-\(filename)")
    }

    nonisolated private static func existingDestinationURL(
        for sourceURL: URL,
        in directoryURL: URL,
        fileManager: FileManager
    ) -> URL? {
        let destinationURL = destinationURL(for: sourceURL, in: directoryURL)
        return fileManager.fileExists(atPath: destinationURL.path) ? destinationURL : nil
    }

    nonisolated private static func destinationURL(for sourceURL: URL, in directoryURL: URL) -> URL {
        let filename = destinationFilename(for: sourceURL)
        return directoryURL.appendingPathComponent(filename)
    }

    nonisolated private static func destinationFilename(for sourceURL: URL) -> String {
        sourceURL.lastPathComponent.isEmpty ? "AppManDownload" : sourceURL.lastPathComponent
    }
}

private let defaultDownloadData: @Sendable (
    URL,
    @escaping @MainActor (DownloadProgress) async -> Void
) async throws -> Data = { url, reportProgress in
    try await streamDownloadData(from: url, reportProgress: reportProgress)
}

private func streamDownloadData(
    from url: URL,
    reportProgress: @escaping @MainActor (DownloadProgress) async -> Void
) async throws -> Data {
    let (bytes, response) = try await URLSession.shared.bytes(from: url)
    let totalBytes = (response.expectedContentLength > 0) ? response.expectedContentLength : nil
    var data = Data()
    var bytesReceived: Int64 = 0

    for try await byte in bytes {
        try Task.checkCancellation()
        data.append(byte)
        bytesReceived += 1

        if bytesReceived == 1 || bytesReceived % 262_144 == 0 || bytesReceived == totalBytes {
            await reportProgress(DownloadProgress(bytesReceived: bytesReceived, totalBytes: totalBytes))
        }
    }

    await reportProgress(DownloadProgress(bytesReceived: bytesReceived, totalBytes: totalBytes))
    return data
}
