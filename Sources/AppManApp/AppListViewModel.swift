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

struct RecipeValidationPresentation: Identifiable, Equatable {
    enum State: Equatable {
        case validating
        case completed(UpdateRecipeValidationResult)
        case failed(String)
    }

    let id: String
    let app: AppRecord
    let recipe: UpdateRecipe
    let recipeJSON: String
    var state: State
}

struct DownloadFailurePrompt: Identifiable, Equatable {
    let appName: String
    let message: String
    let websiteURL: URL

    var id: String {
        "\(appName)|\(websiteURL.absoluteString)"
    }
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
    @Published var uninstallWarningMessage: String?
    @Published private(set) var ignoredApps: [IgnoredAppRecord] = []
    @Published var automaticallyChecksUpdatesOnLaunch = false
    @Published var tinyFishAPIKey = ""
    @Published var errorMessage: String?
    @Published var recipeValidationNotice: String?
    @Published private(set) var recipeValidationPresentation: RecipeValidationPresentation?
    @Published private(set) var downloadFailurePrompt: DownloadFailurePrompt?

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
    private let recipeValidationService: UpdateRecipeValidationService
    private let homebrewUpdater: HomebrewCaskUpdater
    private let downloadedAppInstaller: any DownloadedAppInstalling
    private let appBundleReader: AppBundleReader
    private let fileManager: FileManager
    private let downloadsDirectory: URL?
    private let downloadData: @Sendable (URL, @escaping @MainActor (DownloadProgress) async -> Void) async throws -> Data
    private let revealDownloadedPackage: @MainActor (URL) -> Void
    private let openDownloadedPackage: @MainActor (URL) -> Void
    private let recycleItems: @MainActor @Sendable ([URL]) async -> [URL]
    private var currentUpdateTask: Task<Bool, Never>?

    init(
        scanner: AppScanner = AppScanner(),
        installSourceResolver: InstallSourceResolver = InstallSourceResolver(),
        updateChecker: (any AppUpdateChecking)? = nil,
        appCache: AppRecordCache = AppRecordCache(),
        ignoreListStore: UpdateIgnoreListStore = UpdateIgnoreListStore(),
        preferencesStore: AppPreferencesStore = AppPreferencesStore(),
        selfUpdateSourceStore: SelfUpdateSourceStore = SelfUpdateSourceStore(),
        recipeValidationService: UpdateRecipeValidationService = UpdateRecipeValidationService(),
        homebrewUpdater: HomebrewCaskUpdater = HomebrewCaskUpdater(),
        downloadedAppInstaller: any DownloadedAppInstalling = DownloadedAppInstaller(),
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
        },
        recycleItems: @escaping @MainActor @Sendable ([URL]) async -> [URL] = { urls in
            await withCheckedContinuation { continuation in
                NSWorkspace.shared.recycle(urls) { recycledURLs, _ in
                    let recycledPaths = Set(recycledURLs.keys.map { $0.standardizedFileURL.path })
                    continuation.resume(returning: urls.filter {
                        !recycledPaths.contains($0.standardizedFileURL.path)
                    })
                }
            }
        }
    ) {
        self.scanner = scanner
        self.installSourceResolver = installSourceResolver
        self.injectedUpdateChecker = updateChecker
        self.appCache = appCache
        self.ignoreListStore = ignoreListStore
        self.preferencesStore = preferencesStore
        self.selfUpdateSourceStore = selfUpdateSourceStore
        self.recipeValidationService = recipeValidationService
        self.homebrewUpdater = homebrewUpdater
        self.downloadedAppInstaller = downloadedAppInstaller
        self.appBundleReader = appBundleReader
        self.fileManager = fileManager
        self.downloadsDirectory = downloadsDirectory
        self.downloadData = downloadData
        self.revealDownloadedPackage = revealDownloadedPackage
        self.openDownloadedPackage = openDownloadedPackage
        self.recycleItems = recycleItems
        ignoredApps = (try? ignoreListStore.load()) ?? []
        let preferences = (try? preferencesStore.load()) ?? AppPreferences()
        automaticallyChecksUpdatesOnLaunch = preferences.automaticallyChecksUpdatesOnLaunch
        tinyFishAPIKey = preferences.tinyFishAPIKey
        let loadedCachedApps = (try? appCache.load()) ?? []
        let cachedApps = Self.pruneExistingApps(loadedCachedApps, fileManager: fileManager)
        if cachedApps.count != loadedCachedApps.count {
            try? appCache.save(cachedApps)
        }
        apps = Self.markIgnored(cachedApps, ignoredApps: ignoredApps)
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

    func validateRecipe(for app: AppRecord) async {
        do {
            guard let recipe = try recipeValidationService.matchingRecipe(for: app) else {
                recipeValidationNotice = "“\(app.name)”没有匹配的 Recipe。"
                return
            }

            let recipeJSON = try Self.formattedRecipeJSON(recipe)
            recipeValidationPresentation = RecipeValidationPresentation(
                id: app.path.standardizedFileURL.path,
                app: app,
                recipe: recipe,
                recipeJSON: recipeJSON,
                state: .validating
            )

            let service = recipeValidationService
            let result = try await Task.detached(priority: .userInitiated) {
                try service.validate(app: app, recipe: recipe)
            }.value

            guard recipeValidationPresentation?.id == app.path.standardizedFileURL.path else {
                return
            }
            recipeValidationPresentation?.state = .completed(result)
        } catch {
            if recipeValidationPresentation?.id == app.path.standardizedFileURL.path {
                recipeValidationPresentation?.state = .failed(error.localizedDescription)
            } else {
                recipeValidationNotice = "Recipe 读取失败：\(error.localizedDescription)"
            }
        }
    }

    func dismissRecipeValidation() {
        recipeValidationPresentation = nil
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
            let currentApps = Self.pruneExistingApps(apps, fileManager: fileManager)
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

                    guard let checkedApp = checkedAppsByPath[app.path] else {
                        return app
                    }
                    return Self.preservingLastSuccessfulUpdateIfNeeded(
                        previous: app,
                        checked: checkedApp
                    )
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

    private static func formattedRecipeJSON(_ recipe: UpdateRecipe) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return String(decoding: try encoder.encode(recipe), as: UTF8.self)
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
        uninstallWarningMessage = nil

        do {
            let appCache = self.appCache
            let currentApps = apps
            let updatedApps = currentApps.filter { $0.id != app.id }
            let appPath = app.path.standardizedFileURL.path
            let appURL = candidates.first { $0.url.standardizedFileURL.path == appPath }?.url ?? app.path
            let failedAppItems = await recycleItems([appURL])
            guard failedAppItems.isEmpty else {
                errorMessage = "“\(app.name)”无法移到废纸篓。"
                isUninstalling = false
                return false
            }

            let relatedURLs = candidates
                .filter { $0.url.standardizedFileURL.path != appPath }
                .map(\.url)
            let failedRelatedItems = await recycleItems(relatedURLs)
            try await Task.detached(priority: .userInitiated) {
                try appCache.save(updatedApps)
            }.value

            apps = updatedApps
            if !failedRelatedItems.isEmpty {
                let paths = failedRelatedItems
                    .map { Self.displayPath($0) }
                    .joined(separator: "\n")
                uninstallWarningMessage = "主程序已卸载，但以下关联项未能移到废纸篓：\n\n\(paths)\n\n这些目录可能受到 macOS 隐私保护。请为 AppMan 授予“完全磁盘访问权限”后再清理。"
            }
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
            await refreshHomebrewUpdateStatuses()
        }
    }

    func cancelUpdate() {
        currentUpdateTask?.cancel()
    }

    func clearStatusMessage() {
        statusMessage = nil
    }

    func dismissDownloadFailurePrompt() {
        downloadFailurePrompt = nil
    }

    func openDownloadFailureWebsite(openURL: @MainActor (URL) -> Void) {
        guard let prompt = downloadFailurePrompt else {
            return
        }
        downloadFailurePrompt = nil
        openURL(prompt.websiteURL)
    }

    nonisolated private static func displayPath(_ url: URL) -> String {
        let homePath = FileManager.default.homeDirectoryForCurrentUser.path
        let path = url.path
        guard path.hasPrefix(homePath) else {
            return path
        }
        return "~" + path.dropFirst(homePath.count)
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
            return await updateHomebrewCask(
                app: app,
                token: token,
                refreshAfterUpdate: refreshAfterHomebrewUpdate
            )
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
                return await downloadPackage(from: updateURL, for: app)
            }

            openURL(updateURL)
            return false
        }
    }

    private func downloadPackage(from url: URL, for app: AppRecord) async -> Bool {
        isUpdatingApp = true
        updateProgressText = "正在准备下载..."
        errorMessage = nil
        downloadFailurePrompt = nil
        var didDownload = false
        var downloadedPackageURL: URL?

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
            downloadedPackageURL = destinationURL

            if Self.canAutomaticallyInstall(destinationURL) {
                updateProgressText = destinationURL.pathExtension.lowercased() == "dmg"
                    ? "正在挂载磁盘镜像并安装 App..."
                    : "正在解压缩并安装 App..."
                let installer = downloadedAppInstaller
                let result = try await Task.detached(priority: .userInitiated) {
                    try installer.install(packageURL: destinationURL, replacing: app) { [weak self] progress in
                        Task { @MainActor [weak self] in
                            switch progress {
                            case .requestingQuit:
                                self?.updateProgressText = "正在请求 \(app.name) 退出..."
                            case .waitingForQuit:
                                self?.updateProgressText = "正在等待 \(app.name) 完全退出..."
                            case .replacingApplication:
                                self?.updateProgressText = "正在替换 App..."
                            case .reopeningApplication:
                                self?.updateProgressText = "正在重新打开 \(app.name)..."
                            }
                        }
                    }
                }.value

                switch result {
                case .installed:
                    updateProgressText = "正在刷新 App 信息..."
                    try refreshInstalledApp(app)
                    updateProgressText = "正在将安装包移到废纸篓..."
                    let failedPackages = await recycleItems([destinationURL])
                    statusMessage = failedPackages.isEmpty
                        ? "\(app.name) 已更新"
                        : "\(app.name) 已更新，但安装包未能移到废纸篓"
                case .requiresManualInstallation:
                    updateProgressText = "正在打开安装包..."
                    openDownloadedPackage(destinationURL)
                }
            } else {
                updateProgressText = "正在打开安装包..."
                openDownloadedPackage(destinationURL)
            }
            didDownload = true
        } catch where Self.isCancellation(error) {
            statusMessage = "已取消下载"
            didDownload = false
        } catch DownloadedAppInstallerError.unableToQuitApplication(let name) {
            errorMessage = "\(name) 未能完全退出，已取消更新；旧版本未被替换"
            didDownload = false
        } catch DownloadedAppInstallerError.unableToReopenApplication(let name) {
            try? refreshInstalledApp(app)
            let failedPackages = if let downloadedPackageURL {
                await recycleItems([downloadedPackageURL])
            } else {
                []
            }
            errorMessage = failedPackages.isEmpty
                ? "\(name) 已完成更新，但无法自动重新打开"
                : "\(name) 已完成更新，但无法自动重新打开；安装包未能移到废纸篓"
            didDownload = true
        } catch let error as DownloadedAppInstallerError {
            errorMessage = "更新失败：\(error.localizedDescription)"
        } catch {
            let message = "下载失败：\(error.localizedDescription)"
            if let websiteURL = manualDownloadPage(for: app) {
                downloadFailurePrompt = DownloadFailurePrompt(
                    appName: app.name,
                    message: message,
                    websiteURL: websiteURL
                )
            } else {
                errorMessage = message
            }
        }

        updateProgressText = nil
        isUpdatingApp = false
        return didDownload
    }

    private func manualDownloadPage(for app: AppRecord) -> URL? {
        if let recipe = try? recipeValidationService.matchingRecipe(for: app),
           let updatePageURL = recipe.updatePageURL {
            return updatePageURL
        }

        if let source = try? selfUpdateSourceStore.record(for: app) {
            return source.updateURL
        }

        guard let updateURL = app.updateURL,
              let scheme = updateURL.scheme,
              let host = updateURL.host(percentEncoded: false) else {
            return nil
        }

        let pathComponents = updateURL.pathComponents.filter { $0 != "/" }
        if host.localizedCaseInsensitiveCompare("github.com") == .orderedSame,
           pathComponents.count >= 2 {
            return URL(string: "\(scheme)://\(host)/\(pathComponents[0])/\(pathComponents[1])/releases/latest")
        }

        return URL(string: "\(scheme)://\(host)")
    }

    private func updateHomebrewCask(
        app: AppRecord,
        token: String,
        refreshAfterUpdate: Bool
    ) async -> Bool {
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
                await refreshHomebrewUpdateStatuses(preferredApp: app)
            }
        } catch CommandError.executableNotFound("brew") {
            errorMessage = "Homebrew 不可用"
        } catch {
            errorMessage = HomebrewErrorFormatter.userFacingMessage(from: error)
        }

        updateProgressText = nil
        isUpdatingApp = false
        return didUpdate
    }

    private func refreshHomebrewUpdateStatuses(preferredApp: AppRecord? = nil) async {
        updateProgressText = "正在刷新 Homebrew App 状态..."

        do {
            let checker = makeUpdateChecker()
            let appBundleReader = self.appBundleReader
            let appCache = self.appCache
            let currentApps = apps
            let homebrewApps = currentApps.filter { app in
                if case .homebrewCask = app.installSource {
                    return app.updateStatus != .ignored
                }
                return false
            }
            guard !homebrewApps.isEmpty else {
                return
            }

            let checkedApps = try await Task.detached(priority: .userInitiated) {
                let refreshedApps = homebrewApps.map { app in
                    (try? appBundleReader.refreshMetadata(for: app)) ?? app
                }
                return try checker.checkUpdates(for: refreshedApps)
            }.value

            let checkedByPath = Dictionary(checkedApps.map { ($0.path, $0) }) { _, latest in latest }
            apps = currentApps.map { existingApp in
                guard case .homebrewCask = existingApp.installSource,
                      let checkedApp = checkedByPath[existingApp.path] else {
                    return existingApp
                }
                return Self.preservingLastSuccessfulUpdateIfNeeded(
                    previous: existingApp,
                    checked: checkedApp
                )
            }
            try appCache.save(apps)

            if let preferredApp,
               apps.contains(where: { $0.path == preferredApp.path }) {
                statusMessage = "\(preferredApp.name) 已更新"
            }
        } catch {
            errorMessage = error.localizedDescription
        }
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

    nonisolated private static func pruneExistingApps(
        _ apps: [AppRecord],
        fileManager: FileManager
    ) -> [AppRecord] {
        AppScanner.deduplicated(
            apps.filter { fileManager.fileExists(atPath: $0.path.path) }
        )
    }

    nonisolated private static func preservingLastSuccessfulUpdateIfNeeded(
        previous: AppRecord,
        checked: AppRecord
    ) -> AppRecord {
        guard case .checkFailed = checked.updateStatus else {
            return checked
        }

        switch previous.updateStatus {
        case .upToDate, .updateAvailable:
            return previous
        default:
            return checked
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

    nonisolated private static func canAutomaticallyInstall(_ url: URL) -> Bool {
        ["dmg", "zip"].contains(url.pathExtension.lowercased())
    }

    private func refreshInstalledApp(_ app: AppRecord) throws {
        guard let index = apps.firstIndex(where: { $0.id == app.id && $0.path == app.path }) else {
            return
        }

        var refreshedApp = try appBundleReader.refreshMetadata(for: app)
        refreshedApp.updateStatus = .upToDate
        apps[index] = refreshedApp
        try appCache.save(apps)
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
    do {
        if let totalBytes = try await rangeDownloadSize(for: url) {
            do {
                return try await multipartDownloadData(
                    from: url,
                    totalBytes: totalBytes,
                    partCount: 5,
                    reportProgress: reportProgress
                )
            } catch where isDownloadCancellation(error) {
                throw error
            } catch {
                await reportProgress(DownloadProgress(bytesReceived: 0, totalBytes: totalBytes))
            }
        }
    } catch where isDownloadCancellation(error) {
        throw error
    } catch {
        // HEAD 探测失败时直接使用兼容性更好的单线程下载。
    }

    return try await singleDownloadData(from: url, reportProgress: reportProgress)
}

struct DownloadByteRange: Equatable, Sendable {
    let lowerBound: Int64
    let upperBound: Int64

    var length: Int64 {
        upperBound - lowerBound + 1
    }

    var headerValue: String {
        "bytes=\(lowerBound)-\(upperBound)"
    }
}

func multipartByteRanges(totalBytes: Int64, partCount: Int) -> [DownloadByteRange] {
    guard totalBytes > 0, partCount > 0 else {
        return []
    }

    let actualPartCount = min(Int64(partCount), totalBytes)
    return (0..<actualPartCount).map { index in
        let lowerBound = totalBytes * index / actualPartCount
        let upperBound = totalBytes * (index + 1) / actualPartCount - 1
        return DownloadByteRange(lowerBound: lowerBound, upperBound: upperBound)
    }
}

private func rangeDownloadSize(for url: URL) async throws -> Int64? {
    var request = URLRequest(url: url)
    request.httpMethod = "HEAD"
    request.timeoutInterval = 20
    let (_, response) = try await URLSession.shared.data(for: request)
    guard let httpResponse = response as? HTTPURLResponse,
          (200...299).contains(httpResponse.statusCode),
          httpResponse.value(forHTTPHeaderField: "Accept-Ranges")?.lowercased().contains("bytes") == true,
          response.expectedContentLength > 0 else {
        return nil
    }
    return response.expectedContentLength
}

private func multipartDownloadData(
    from url: URL,
    totalBytes: Int64,
    partCount: Int,
    reportProgress: @escaping @MainActor (DownloadProgress) async -> Void
) async throws -> Data {
    guard totalBytes <= Int64(Int.max) else {
        throw MultipartDownloadError.fileTooLarge
    }

    let ranges = multipartByteRanges(totalBytes: totalBytes, partCount: partCount)
    guard ranges.count > 1 else {
        return try await singleDownloadData(from: url, reportProgress: reportProgress)
    }

    let progress = MultipartDownloadProgress(totalBytes: totalBytes, reportProgress: reportProgress)
    let buffer = NSMutableData(length: Int(totalBytes))!

    do {
        try await withThrowingTaskGroup(of: Void.self) { group in
            for range in ranges {
                group.addTask {
                    var request = URLRequest(url: url)
                    request.setValue(range.headerValue, forHTTPHeaderField: "Range")
                    let receiver = MultipartPartReceiver(
                        range: range,
                        buffer: buffer,
                        progress: progress
                    )
                    let response = try await collectDownloadData(
                        request: request,
                        collectsData: false,
                        validateResponse: { response in
                            try validateRangeResponseHeader(
                                response,
                                expectedRange: range,
                                totalBytes: totalBytes
                            )
                        }
                    ) { chunk in
                        receiver.receive(chunk)
                    }
                    try validateRangeResponseBody(response, expectedRange: range)
                    try receiver.validateCompletedLength()
                }
            }

            try await group.waitForAll()
        }
    } catch {
        progress.stop()
        throw error
    }

    progress.stop()
    await reportProgress(DownloadProgress(bytesReceived: totalBytes, totalBytes: totalBytes))
    return Data(referencing: buffer)
}

private func singleDownloadData(
    from url: URL,
    reportProgress: @escaping @MainActor (DownloadProgress) async -> Void
) async throws -> Data {
    let progress = SingleDownloadProgress(reportProgress: reportProgress)
    let response = try await collectDownloadData(request: URLRequest(url: url)) { chunk in
        progress.add(Int64(chunk.count))
    } onResponse: { totalBytes in
        progress.setTotalBytes(totalBytes)
    }
    progress.stop()
    await reportProgress(DownloadProgress(
        bytesReceived: Int64(response.data.count),
        totalBytes: response.response.expectedContentLength > 0
            ? response.response.expectedContentLength
            : nil
    ))
    return response.data
}

private struct CollectedDownloadData: Sendable {
    let data: Data
    let response: URLResponse
    let bytesReceived: Int64
}

private func collectDownloadData(
    request: URLRequest,
    collectsData: Bool = true,
    validateResponse: @escaping @Sendable (URLResponse) throws -> Void = { _ in },
    onData: @escaping @Sendable (Data) -> Void,
    onResponse: @escaping @Sendable (Int64?) -> Void = { _ in }
) async throws -> CollectedDownloadData {
    let download = StreamingDataDownload(
        collectsData: collectsData,
        validateResponse: validateResponse,
        onData: onData,
        onResponse: onResponse
    )
    return try await withTaskCancellationHandler {
        try await download.start(request: request)
    } onCancel: {
        download.cancel()
    }
}

private func validateRangeResponseHeader(
    _ response: URLResponse,
    expectedRange: DownloadByteRange,
    totalBytes: Int64
) throws {
    guard let httpResponse = response as? HTTPURLResponse,
          httpResponse.statusCode == 206 else {
        throw MultipartDownloadError.rangeNotSupported
    }

    let expectedContentRange = "bytes \(expectedRange.lowerBound)-\(expectedRange.upperBound)/\(totalBytes)"
    guard httpResponse.value(forHTTPHeaderField: "Content-Range")?.lowercased() == expectedContentRange else {
        throw MultipartDownloadError.incorrectContentRange
    }
}

private func validateRangeResponseBody(
    _ response: CollectedDownloadData,
    expectedRange: DownloadByteRange
) throws {
    guard response.bytesReceived == expectedRange.length else {
        throw MultipartDownloadError.incorrectPartLength
    }
}

private final class StreamingDataDownload: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let collectsData: Bool
    private let validateResponse: @Sendable (URLResponse) throws -> Void
    private let onData: @Sendable (Data) -> Void
    private let onResponse: @Sendable (Int64?) -> Void
    private let lock = NSLock()
    private var continuation: CheckedContinuation<CollectedDownloadData, Error>?
    private var session: URLSession?
    private var task: URLSessionDataTask?
    private var data = Data()
    private var bytesReceived: Int64 = 0
    private var response: URLResponse?
    private var responseError: Error?
    private var isCancelled = false

    init(
        collectsData: Bool,
        validateResponse: @escaping @Sendable (URLResponse) throws -> Void,
        onData: @escaping @Sendable (Data) -> Void,
        onResponse: @escaping @Sendable (Int64?) -> Void
    ) {
        self.collectsData = collectsData
        self.validateResponse = validateResponse
        self.onData = onData
        self.onResponse = onResponse
    }

    func start(request: URLRequest) async throws -> CollectedDownloadData {
        try await withCheckedThrowingContinuation { continuation in
            let delegateQueue = OperationQueue()
            delegateQueue.maxConcurrentOperationCount = 1
            let session = URLSession(configuration: .default, delegate: self, delegateQueue: delegateQueue)
            let task = session.dataTask(with: request)

            lock.lock()
            self.continuation = continuation
            self.session = session
            self.task = task
            let shouldCancel = isCancelled
            lock.unlock()

            if shouldCancel {
                task.cancel()
            } else {
                task.resume()
            }
        }
    }

    func cancel() {
        lock.lock()
        isCancelled = true
        let task = self.task
        lock.unlock()
        task?.cancel()
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        do {
            try validateResponse(response)
        } catch {
            lock.lock()
            responseError = error
            lock.unlock()
            completionHandler(.cancel)
            return
        }

        lock.lock()
        self.response = response
        lock.unlock()
        onResponse(response.expectedContentLength > 0 ? response.expectedContentLength : nil)
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive chunk: Data) {
        lock.lock()
        if collectsData {
            data.append(chunk)
        }
        bytesReceived += Int64(chunk.count)
        lock.unlock()
        onData(chunk)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        lock.lock()
        let continuation = self.continuation
        self.continuation = nil
        self.task = nil
        self.session = nil
        let resultData = data
        let response = self.response
        let responseError = self.responseError
        let bytesReceived = self.bytesReceived
        lock.unlock()

        session.finishTasksAndInvalidate()
        if let responseError {
            continuation?.resume(throwing: responseError)
            return
        }
        if let error {
            continuation?.resume(throwing: error)
            return
        }
        guard let response else {
            continuation?.resume(throwing: MultipartDownloadError.missingResponse)
            return
        }
        continuation?.resume(returning: CollectedDownloadData(
            data: resultData,
            response: response,
            bytesReceived: bytesReceived
        ))
    }
}

private final class MultipartPartReceiver: @unchecked Sendable {
    private let range: DownloadByteRange
    private let buffer: NSMutableData
    private let progress: MultipartDownloadProgress
    private let lock = NSLock()
    private var bytesReceived: Int64 = 0

    init(
        range: DownloadByteRange,
        buffer: NSMutableData,
        progress: MultipartDownloadProgress
    ) {
        self.range = range
        self.buffer = buffer
        self.progress = progress
    }

    func receive(_ chunk: Data) {
        lock.lock()
        guard bytesReceived + Int64(chunk.count) <= range.length else {
            bytesReceived += Int64(chunk.count)
            lock.unlock()
            return
        }
        let writeOffset = range.lowerBound + bytesReceived
        bytesReceived += Int64(chunk.count)
        lock.unlock()

        chunk.withUnsafeBytes { bytes in
            guard let baseAddress = bytes.baseAddress else {
                return
            }
            objc_sync_enter(buffer)
            buffer.replaceBytes(
                in: NSRange(location: Int(writeOffset), length: chunk.count),
                withBytes: baseAddress
            )
            objc_sync_exit(buffer)
        }
        progress.add(Int64(chunk.count))
    }

    func validateCompletedLength() throws {
        lock.lock()
        let completedBytes = bytesReceived
        lock.unlock()
        guard completedBytes == range.length else {
            throw MultipartDownloadError.incorrectPartLength
        }
    }
}

private final class MultipartDownloadProgress: @unchecked Sendable {
    private let totalBytes: Int64
    private let reportProgress: @MainActor (DownloadProgress) async -> Void
    private let lock = NSLock()
    private var bytesReceived: Int64 = 0
    private var lastReportedBytes: Int64 = 0
    private var isActive = true

    init(
        totalBytes: Int64,
        reportProgress: @escaping @MainActor (DownloadProgress) async -> Void
    ) {
        self.totalBytes = totalBytes
        self.reportProgress = reportProgress
    }

    func add(_ count: Int64) {
        lock.lock()
        guard isActive else {
            lock.unlock()
            return
        }
        bytesReceived += count
        let progress = DownloadProgress(bytesReceived: bytesReceived, totalBytes: totalBytes)
        let shouldReport = lastReportedBytes == 0
            || bytesReceived - lastReportedBytes >= 262_144
            || bytesReceived == totalBytes
        if shouldReport {
            lastReportedBytes = bytesReceived
        }
        lock.unlock()

        if shouldReport {
            Task { @MainActor [weak self] in
                guard let self, self.active else {
                    return
                }
                await self.reportProgress(progress)
            }
        }
    }

    func stop() {
        lock.lock()
        isActive = false
        lock.unlock()
    }

    private var active: Bool {
        lock.lock()
        defer { lock.unlock() }
        return isActive
    }
}

private final class SingleDownloadProgress: @unchecked Sendable {
    private let reportProgress: @MainActor (DownloadProgress) async -> Void
    private let lock = NSLock()
    private var bytesReceived: Int64 = 0
    private var totalBytes: Int64?
    private var lastReportedBytes: Int64 = 0
    private var isActive = true

    init(reportProgress: @escaping @MainActor (DownloadProgress) async -> Void) {
        self.reportProgress = reportProgress
    }

    func setTotalBytes(_ totalBytes: Int64?) {
        lock.lock()
        self.totalBytes = totalBytes
        lock.unlock()
    }

    func add(_ count: Int64) {
        lock.lock()
        guard isActive else {
            lock.unlock()
            return
        }
        bytesReceived += count
        let progress = DownloadProgress(bytesReceived: bytesReceived, totalBytes: totalBytes)
        let shouldReport = lastReportedBytes == 0
            || bytesReceived - lastReportedBytes >= 262_144
            || bytesReceived == totalBytes
        if shouldReport {
            lastReportedBytes = bytesReceived
        }
        lock.unlock()

        if shouldReport {
            Task { @MainActor [weak self] in
                guard let self, self.active else {
                    return
                }
                await self.reportProgress(progress)
            }
        }
    }

    func stop() {
        lock.lock()
        isActive = false
        lock.unlock()
    }

    private var active: Bool {
        lock.lock()
        defer { lock.unlock() }
        return isActive
    }
}

private enum MultipartDownloadError: LocalizedError {
    case fileTooLarge
    case missingResponse
    case rangeNotSupported
    case incorrectPartLength
    case incorrectContentRange

    var errorDescription: String? {
        switch self {
        case .fileTooLarge:
            return "文件过大"
        case .missingResponse:
            return "没有收到下载响应"
        case .rangeNotSupported:
            return "服务器不支持分块下载"
        case .incorrectPartLength:
            return "分块长度不正确"
        case .incorrectContentRange:
            return "分块范围响应不正确"
        }
    }
}

private func isDownloadCancellation(_ error: Error) -> Bool {
    if error is CancellationError {
        return true
    }
    return (error as? URLError)?.code == .cancelled
}
