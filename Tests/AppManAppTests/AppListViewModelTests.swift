import XCTest
@testable import AppManApp
import AppManCore

final class AppListViewModelTests: XCTestCase {
    func testMultipartByteRangesSplitFileIntoFiveContinuousParts() {
        XCTAssertEqual(
            multipartByteRanges(totalBytes: 13, partCount: 5),
            [
                DownloadByteRange(lowerBound: 0, upperBound: 1),
                DownloadByteRange(lowerBound: 2, upperBound: 4),
                DownloadByteRange(lowerBound: 5, upperBound: 6),
                DownloadByteRange(lowerBound: 7, upperBound: 9),
                DownloadByteRange(lowerBound: 10, upperBound: 12),
            ]
        )
    }

    func testMultipartByteRangesDoNotCreateEmptyParts() {
        XCTAssertEqual(
            multipartByteRanges(totalBytes: 3, partCount: 5),
            [
                DownloadByteRange(lowerBound: 0, upperBound: 0),
                DownloadByteRange(lowerBound: 1, upperBound: 1),
                DownloadByteRange(lowerBound: 2, upperBound: 2),
            ]
        )
    }

    @MainActor
    func testCheckAllUpdatesShowsCompletedProgress() async {
        let apps = [
            makeManualApp(id: "one"),
            makeManualApp(id: "two"),
            makeManualApp(id: "three"),
        ]
        let checker = StepwiseUpdateChecker()
        let viewModel = AppListViewModel(
            updateChecker: checker,
            appCache: AppRecordCache(cacheURL: temporaryCacheURL(), fileManager: .default)
        )
        viewModel.replaceAppsForTesting(apps)

        let checkTask = Task {
            await viewModel.checkUpdates()
        }

        await checker.waitUntilStarted(count: 1)
        checker.finishNext()
        await waitUntil {
            viewModel.updateProgressText == "正在检查更新... (1/3)"
        }
        XCTAssertEqual(viewModel.updateProgressText, "正在检查更新... (1/3)")

        checker.finishNext()
        await waitUntil {
            viewModel.updateProgressText == "正在检查更新... (2/3)"
        }
        XCTAssertEqual(viewModel.updateProgressText, "正在检查更新... (2/3)")

        checker.finishNext()
        await checkTask.value

        XCTAssertNil(viewModel.updateProgressText)
        XCTAssertFalse(viewModel.isCheckingUpdates)
    }

    @MainActor
    func testCheckAllUpdatesUsesInjectedCheckerInOneBatch() async {
        let apps = [
            makeManualApp(id: "one"),
            makeManualApp(id: "two"),
            makeManualApp(id: "three"),
        ]
        let checker = BatchRecordingUpdateChecker()
        let viewModel = AppListViewModel(
            updateChecker: checker,
            appCache: AppRecordCache(cacheURL: temporaryCacheURL(), fileManager: .default)
        )
        viewModel.replaceAppsForTesting(apps)

        await viewModel.checkUpdates()

        XCTAssertEqual(checker.batchSizes, [3])
        XCTAssertEqual(viewModel.apps.map(\.updateStatus), [.upToDate, .upToDate, .upToDate])
    }

    @MainActor
    func testCheckFailurePreservesLastSuccessfulUpdateResult() async throws {
        let appURL = temporaryAppBundleURL(name: "Cached")
        try FileManager.default.createDirectory(at: appURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: appURL.deletingLastPathComponent()) }
        var app = makeManualApp(id: "cached", path: appURL)
        app.updateStatus = .updateAvailable(installedVersion: "1.0", latestVersion: "2.0")
        app.updateURL = URL(string: "https://example.com/App-2.0-arm64.dmg")
        app.updateURLIsDirectDownload = true
        let viewModel = AppListViewModel(
            updateChecker: FailingResultUpdateChecker(),
            appCache: AppRecordCache(cacheURL: temporaryCacheURL(), fileManager: .default)
        )
        viewModel.replaceAppsForTesting([app])

        await viewModel.checkUpdates()

        XCTAssertEqual(viewModel.apps, [app])
    }

    @MainActor
    func testLaunchDropsCachedAppsThatNoLongerExist() throws {
        let existingAppURL = temporaryAppBundleURL(name: "Existing")
        let removedAppURL = temporaryAppBundleURL(name: "Removed")
        try FileManager.default.createDirectory(
            at: existingAppURL.appendingPathComponent("Contents", isDirectory: true),
            withIntermediateDirectories: true
        )
        let existingApp = makeManualApp(id: "existing", path: existingAppURL)
        let removedApp = makeManualApp(id: "removed", path: removedAppURL)
        let cache = AppRecordCache(cacheURL: temporaryCacheURL(), fileManager: .default)
        try cache.save([existingApp, removedApp])

        let viewModel = AppListViewModel(appCache: cache)

        XCTAssertEqual(viewModel.apps.map(\.path), [existingAppURL])
        XCTAssertEqual(try cache.load().map(\.path), [existingAppURL])
    }

    @MainActor
    func testLaunchDropsCachedAppsWithDuplicateBundleIdentifier() throws {
        let firstAppURL = temporaryAppBundleURL(name: "First")
        let secondAppURL = temporaryAppBundleURL(name: "Second")
        defer {
            try? FileManager.default.removeItem(at: firstAppURL.deletingLastPathComponent())
            try? FileManager.default.removeItem(at: secondAppURL.deletingLastPathComponent())
        }
        try FileManager.default.createDirectory(
            at: firstAppURL.appendingPathComponent("Contents", isDirectory: true),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: secondAppURL.appendingPathComponent("Contents", isDirectory: true),
            withIntermediateDirectories: true
        )
        let firstApp = makeManualApp(id: "duplicate", path: firstAppURL)
        let secondApp = makeManualApp(id: "duplicate", path: secondAppURL)
        let cache = AppRecordCache(cacheURL: temporaryCacheURL(), fileManager: .default)
        try cache.save([firstApp, secondApp])

        let viewModel = AppListViewModel(appCache: cache)

        XCTAssertEqual(viewModel.apps.map(\.path), [firstAppURL])
        XCTAssertEqual(try cache.load().map(\.path), [firstAppURL])
    }

    @MainActor
    func testCheckAllUpdatesDropsCachedAppsThatNoLongerExist() async {
        let existingAppURL = temporaryAppBundleURL(name: "Existing")
        let removedAppURL = temporaryAppBundleURL(name: "Removed")
        try? FileManager.default.createDirectory(
            at: existingAppURL.appendingPathComponent("Contents", isDirectory: true),
            withIntermediateDirectories: true
        )
        let existingApp = makeManualApp(id: "existing", path: existingAppURL)
        let removedApp = makeManualApp(id: "removed", path: removedAppURL)
        let checker = BatchRecordingUpdateChecker()
        let cache = AppRecordCache(cacheURL: temporaryCacheURL(), fileManager: .default)
        let viewModel = AppListViewModel(updateChecker: checker, appCache: cache)
        viewModel.replaceAppsForTesting([existingApp, removedApp])

        await viewModel.checkUpdates()

        XCTAssertEqual(checker.batchSizes, [1])
        XCTAssertEqual(viewModel.apps.map(\.path), [existingAppURL])
        XCTAssertEqual((try? cache.load().map(\.path)), [existingAppURL])
    }

    @MainActor
    func testUninstallSucceedsWhenAppIsTrashedButRelatedItemFails() async throws {
        let appURL = temporaryAppBundleURL(name: "Clash Mi")
        let relatedURL = appURL.deletingLastPathComponent().appendingPathComponent("group.com.nebula.clashmi")
        let app = makeManualApp(id: "clash-mi", path: appURL)
        let cache = AppRecordCache(cacheURL: temporaryCacheURL(), fileManager: .default)
        try cache.save([app])
        let viewModel = AppListViewModel(
            appCache: cache,
            recycleItems: { urls in
                urls.filter { $0 == relatedURL }
            }
        )
        viewModel.replaceAppsForTesting([app])
        let candidates = [
            UninstallCandidate(url: appURL, name: "Clash Mi", kind: .application, sizeBytes: 1, isRequired: true),
            UninstallCandidate(url: relatedURL, name: relatedURL.lastPathComponent, kind: .groupContainer, sizeBytes: 1),
        ]

        let didUninstall = await viewModel.uninstall(app, candidates: candidates)

        XCTAssertTrue(didUninstall)
        XCTAssertTrue(viewModel.apps.isEmpty)
        XCTAssertEqual(try cache.load(), [])
        XCTAssertNil(viewModel.errorMessage)
        XCTAssertEqual(
            viewModel.uninstallWarningMessage,
            "主程序已卸载，但以下关联项未能移到废纸篓：\n\n\(relatedURL.path)\n\n这些目录可能受到 macOS 隐私保护。请为 AppMan 授予“完全磁盘访问权限”后再清理。"
        )
    }

    @MainActor
    func testUninstallFailsWhenAppCannotBeTrashed() async {
        let appURL = temporaryAppBundleURL(name: "Clash Mi")
        let app = makeManualApp(id: "clash-mi", path: appURL)
        let viewModel = AppListViewModel(
            recycleItems: { urls in
                urls
            }
        )
        viewModel.replaceAppsForTesting([app])
        let candidate = UninstallCandidate(
            url: appURL,
            name: "Clash Mi",
            kind: .application,
            sizeBytes: 1,
            isRequired: true
        )

        let didUninstall = await viewModel.uninstall(app, candidates: [candidate])

        XCTAssertFalse(didUninstall)
        XCTAssertEqual(viewModel.apps, [app])
        XCTAssertNotNil(viewModel.errorMessage)
    }

    func testAppInfoDetailsExposeWebsiteAndDirectLatestVersionLink() {
        let app = AppRecord(
            id: "com.example.direct",
            name: "Direct",
            bundleIdentifier: "com.example.direct",
            shortVersion: "1.0",
            buildVersion: "100",
            path: URL(fileURLWithPath: "/Applications/Direct.app"),
            sizeBytes: 1,
            installSource: .manual(reason: "self"),
            updateStatus: .updateAvailable(installedVersion: "1.0", latestVersion: "2.0"),
            updateURL: URL(string: "https://updates.example.com/downloads/Direct-2.0.dmg")!,
            updateURLIsDirectDownload: true
        )

        let details = AppInfoDetails(app: app)

        XCTAssertEqual(details.latestVersion, "2.0")
        XCTAssertEqual(details.websiteTitle, "updates.example.com")
        XCTAssertEqual(details.websiteURL, URL(string: "https://updates.example.com"))
        XCTAssertEqual(details.latestVersionLinkTitle, "下载链接")
        XCTAssertEqual(details.latestVersionURL, URL(string: "https://updates.example.com/downloads/Direct-2.0.dmg"))
    }

    func testAppInfoDetailsUsesGitHubProjectPageAsWebsite() {
        let app = AppRecord(
            id: "2dust.v2rayN",
            name: "v2rayN",
            bundleIdentifier: "2dust.v2rayN",
            shortVersion: "7.20.4",
            buildVersion: nil,
            path: URL(fileURLWithPath: "/Applications/v2rayN.app"),
            sizeBytes: 1,
            installSource: .manual(reason: "self"),
            updateStatus: .updateAvailable(installedVersion: "7.20.4", latestVersion: "7.22.7"),
            updateURL: URL(string: "https://github.com/2dust/v2rayN/releases/download/7.22.7/v2rayN-macos-arm64.dmg")!,
            updateURLIsDirectDownload: true
        )

        let details = AppInfoDetails(app: app)

        XCTAssertEqual(details.websiteTitle, "github.com/2dust/v2rayN")
        XCTAssertEqual(details.websiteURL, URL(string: "https://github.com/2dust/v2rayN"))
        XCTAssertEqual(details.latestVersionLinkTitle, "下载链接")
        XCTAssertEqual(details.latestVersionURL, URL(string: "https://github.com/2dust/v2rayN/releases/download/7.22.7/v2rayN-macos-arm64.dmg"))
    }

    func testAppInfoDetailsExposePendingWebsiteCandidate() {
        let candidateURL = URL(string: "https://example.com/app/download")!
        let app = AppRecord(
            id: "com.example.pending",
            name: "Pending",
            bundleIdentifier: "com.example.pending",
            shortVersion: "1.0",
            buildVersion: nil,
            path: URL(fileURLWithPath: "/Applications/Pending.app"),
            sizeBytes: 1,
            installSource: .manual(reason: "self"),
            updateStatus: .needsOfficialWebsiteConfirmation(candidateURL: candidateURL)
        )

        let details = AppInfoDetails(app: app)

        XCTAssertEqual(details.websiteTitle, "example.com")
        XCTAssertEqual(details.websiteURL, URL(string: "https://example.com"))
        XCTAssertEqual(details.latestVersion, "待确认")
        XCTAssertEqual(details.latestVersionLinkTitle, "候选官网")
        XCTAssertEqual(details.latestVersionURL, candidateURL)
    }

    func testDirectDownloadUpdateURLDoesNotRequirePackageExtension() {
        let app = AppRecord(
            id: "com.microsoft.VSCode",
            name: "Visual Studio Code",
            bundleIdentifier: "com.microsoft.VSCode",
            shortVersion: "1.0",
            buildVersion: nil,
            path: URL(fileURLWithPath: "/Applications/Visual Studio Code.app"),
            sizeBytes: 1,
            installSource: .manual(reason: "self"),
            updateStatus: .updateAvailable(installedVersion: "1.0", latestVersion: "2.0"),
            updateURL: URL(string: "https://update.code.visualstudio.com/latest/darwin-arm64/stable")!,
            updateURLIsDirectDownload: true
        )

        XCTAssertTrue(AppListViewModel.shouldDownloadPackage(for: app))
    }

    func testWebUpdateURLFallsBackToOpeningURL() {
        let app = AppRecord(
            id: "net.freemacsoft.AppCleaner",
            name: "AppCleaner",
            bundleIdentifier: "net.freemacsoft.AppCleaner",
            shortVersion: "1.0",
            buildVersion: nil,
            path: URL(fileURLWithPath: "/Applications/AppCleaner.app"),
            sizeBytes: 1,
            installSource: .manual(reason: "self"),
            updateStatus: .updateAvailable(installedVersion: "1.0", latestVersion: "2.0"),
            updateURL: URL(string: "https://freemacsoft.net/appcleaner/")!,
            updateURLIsDirectDownload: false
        )

        XCTAssertFalse(AppListViewModel.shouldDownloadPackage(for: app))
    }

    @MainActor
    func testDownloadUpdateShowsByteProgress() async {
        let app = AppRecord(
            id: "com.example.direct",
            name: "Direct",
            bundleIdentifier: "com.example.direct",
            shortVersion: "1.0",
            buildVersion: nil,
            path: URL(fileURLWithPath: "/Applications/Direct.app"),
            sizeBytes: 1,
            installSource: .manual(reason: "self"),
            updateStatus: .updateAvailable(installedVersion: "1.0", latestVersion: "2.0"),
            updateURL: URL(string: "https://example.com/Direct.zip")!,
            updateURLIsDirectDownload: true
        )
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }
        let viewModelBox = ViewModelBox()
        let viewModel = AppListViewModel(
            fileManager: FileManager.default,
            downloadsDirectory: temporaryDirectory,
            downloadData: { _, reportProgress in
                await reportProgress(DownloadProgress(
                    bytesReceived: 1_572_864,
                    totalBytes: 10_485_760
                ))
                await MainActor.run {
                    XCTAssertEqual(
                        viewModelBox.viewModel?.updateProgressText,
                        "正在下载安装包...\n总大小 10.5 MB，已下载 1.6 MB (15%)"
                    )
                }
                return Data("package".utf8)
            },
            revealDownloadedPackage: { _ in }
        )
        viewModelBox.viewModel = viewModel

        await viewModel.update(app) { _ in
            XCTFail("Direct download should not open the update URL")
        }

        XCTAssertFalse(viewModel.isUpdatingApp)
        XCTAssertNil(viewModel.updateProgressText)
    }

    @MainActor
    func testDownloadUpdateRevealsExistingPackageWithoutDownloadingAgain() async throws {
        let app = AppRecord(
            id: "com.example.existing",
            name: "Existing",
            bundleIdentifier: "com.example.existing",
            shortVersion: "1.0",
            buildVersion: nil,
            path: URL(fileURLWithPath: "/Applications/Existing.app"),
            sizeBytes: 1,
            installSource: .manual(reason: "self"),
            updateStatus: .updateAvailable(installedVersion: "1.0", latestVersion: "2.0"),
            updateURL: URL(string: "https://example.com/Existing.zip")!,
            updateURLIsDirectDownload: true
        )
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let appManDownloadsDirectory = temporaryDirectory.appendingPathComponent("AppMan", isDirectory: true)
        let existingPackageURL = appManDownloadsDirectory.appendingPathComponent("Existing.zip")
        try FileManager.default.createDirectory(at: appManDownloadsDirectory, withIntermediateDirectories: true)
        try Data("existing-package".utf8).write(to: existingPackageURL)
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }
        var revealedURL: URL?
        let viewModel = AppListViewModel(
            fileManager: FileManager.default,
            downloadsDirectory: temporaryDirectory,
            downloadData: { _, _ in
                XCTFail("Existing package should be reused without downloading again")
                return Data()
            },
            revealDownloadedPackage: { url in
                revealedURL = url
            }
        )

        await viewModel.update(app) { _ in
            XCTFail("Direct download should not open the update URL")
        }

        XCTAssertEqual(revealedURL, existingPackageURL)
        XCTAssertNil(viewModel.updateProgressText)
    }

    @MainActor
    func testDownloadUpdateOpensNewPackageAfterSaving() async throws {
        let app = AppRecord(
            id: "com.example.new-package",
            name: "NewPackage",
            bundleIdentifier: "com.example.new-package",
            shortVersion: "1.0",
            buildVersion: nil,
            path: URL(fileURLWithPath: "/Applications/NewPackage.app"),
            sizeBytes: 1,
            installSource: .manual(reason: "self"),
            updateStatus: .updateAvailable(installedVersion: "1.0", latestVersion: "2.0"),
            updateURL: URL(string: "https://example.com/NewPackage.dmg")!,
            updateURLIsDirectDownload: true
        )
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }
        var revealedURL: URL?
        var openedPackageURL: URL?
        let viewModel = AppListViewModel(
            downloadedAppInstaller: StubDownloadedAppInstaller(result: .requiresManualInstallation),
            fileManager: FileManager.default,
            downloadsDirectory: temporaryDirectory,
            downloadData: { _, _ in
                Data("new-package".utf8)
            },
            revealDownloadedPackage: { url in
                revealedURL = url
            },
            openDownloadedPackage: { url in
                openedPackageURL = url
            },
            recycleItems: { _ in
                XCTFail("Packages requiring manual installation must be kept")
                return []
            }
        )

        await viewModel.update(app) { _ in
            XCTFail("Direct download should not open the update URL")
        }

        let expectedPackageURL = temporaryDirectory
            .appendingPathComponent("AppMan", isDirectory: true)
            .appendingPathComponent("NewPackage.dmg")
        XCTAssertNil(revealedURL)
        XCTAssertEqual(openedPackageURL, expectedPackageURL)
        XCTAssertTrue(FileManager.default.fileExists(atPath: expectedPackageURL.path))
        XCTAssertNil(viewModel.updateProgressText)
    }

    @MainActor
    func testDownloadUpdateAutomaticallyInstallsAppFromArchive() async throws {
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let appURL = temporaryDirectory.appendingPathComponent("Applications/Direct.app", isDirectory: true)
        try makeTestAppBundle(at: appURL, version: "1.0")
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }
        var app = makeManualApp(id: "direct", path: appURL)
        app.updateStatus = .updateAvailable(installedVersion: "1.0", latestVersion: "2.0")
        app.updateURL = URL(string: "https://example.com/Direct.zip")!
        app.updateURLIsDirectDownload = true
        let installer = StubDownloadedAppInstaller(result: .installed(appURL)) { _, _ in
            try makeTestAppBundle(at: appURL, version: "2.0", replaceExisting: true)
        }
        let cache = AppRecordCache(cacheURL: temporaryCacheURL(), fileManager: .default)
        var recycledURLs: [URL] = []
        let viewModel = AppListViewModel(
            appCache: cache,
            downloadedAppInstaller: installer,
            fileManager: .default,
            downloadsDirectory: temporaryDirectory,
            downloadData: { _, _ in Data("archive".utf8) },
            openDownloadedPackage: { _ in
                XCTFail("Archive containing an App should be installed automatically")
            },
            recycleItems: { urls in
                recycledURLs = urls
                return []
            }
        )
        viewModel.replaceAppsForTesting([app])

        await viewModel.update(app) { _ in
            XCTFail("Direct download should not open the update URL")
        }

        XCTAssertEqual(viewModel.apps.first?.shortVersion, "2.0")
        XCTAssertEqual(viewModel.apps.first?.updateStatus, .upToDate)
        XCTAssertEqual(viewModel.statusMessage, "direct 已更新")
        XCTAssertEqual(try cache.load().first?.shortVersion, "2.0")
        XCTAssertEqual(
            recycledURLs,
            [
                temporaryDirectory
                    .appendingPathComponent("AppMan", isDirectory: true)
                    .appendingPathComponent("Direct.zip"),
            ]
        )
    }

    @MainActor
    func testInstalledPackageIsRecycledWhenUpdatedAppCannotReopen() async throws {
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let appURL = temporaryDirectory.appendingPathComponent("Applications/Direct.app", isDirectory: true)
        try makeTestAppBundle(at: appURL, version: "1.0")
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }
        var app = makeManualApp(id: "direct", path: appURL)
        app.updateStatus = .updateAvailable(installedVersion: "1.0", latestVersion: "2.0")
        app.updateURL = URL(string: "https://example.com/Direct.zip")!
        app.updateURLIsDirectDownload = true
        let installer = StubDownloadedAppInstaller(result: .installed(appURL)) { _, _ in
            try makeTestAppBundle(at: appURL, version: "2.0", replaceExisting: true)
            throw DownloadedAppInstallerError.unableToReopenApplication("direct")
        }
        var recycledURLs: [URL] = []
        let viewModel = AppListViewModel(
            downloadedAppInstaller: installer,
            fileManager: .default,
            downloadsDirectory: temporaryDirectory,
            downloadData: { _, _ in Data("archive".utf8) },
            recycleItems: { urls in
                recycledURLs = urls
                return []
            }
        )
        viewModel.replaceAppsForTesting([app])

        await viewModel.update(app) { _ in
            XCTFail("Direct download should not open the update URL")
        }

        XCTAssertEqual(viewModel.apps.first?.shortVersion, "2.0")
        XCTAssertEqual(viewModel.errorMessage, "direct 已完成更新，但无法自动重新打开")
        XCTAssertEqual(
            recycledURLs,
            [
                temporaryDirectory
                    .appendingPathComponent("AppMan", isDirectory: true)
                    .appendingPathComponent("Direct.zip"),
            ]
        )
    }

    @MainActor
    func testCancelUpdateShowsCancelledHintWithoutFailureAlert() async throws {
        let app = AppRecord(
            id: "com.example.cancel",
            name: "Cancel",
            bundleIdentifier: "com.example.cancel",
            shortVersion: "1.0",
            buildVersion: nil,
            path: URL(fileURLWithPath: "/Applications/Cancel.app"),
            sizeBytes: 1,
            installSource: .manual(reason: "self"),
            updateStatus: .updateAvailable(installedVersion: "1.0", latestVersion: "2.0"),
            updateURL: URL(string: "https://example.com/Cancel.zip")!,
            updateURLIsDirectDownload: true
        )
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }
        let started = AsyncSignal()
        let viewModel = AppListViewModel(
            fileManager: FileManager.default,
            downloadsDirectory: temporaryDirectory,
            downloadData: { _, reportProgress in
                await reportProgress(DownloadProgress(bytesReceived: 1, totalBytes: 10))
                await started.signal()
                while !Task.isCancelled {
                    try await Task.sleep(nanoseconds: 10_000_000)
                }
                throw URLError(.cancelled)
            },
            revealDownloadedPackage: { _ in
                XCTFail("Cancelled downloads should not reveal a file")
            }
        )

        let updateTask = Task {
            await viewModel.update(app) { _ in
                XCTFail("Direct download should not open the update URL")
            }
        }
        await started.wait()

        viewModel.cancelUpdate()
        await updateTask.value

        XCTAssertFalse(viewModel.isUpdatingApp)
        XCTAssertNil(viewModel.updateProgressText)
        XCTAssertNil(viewModel.errorMessage)
        XCTAssertEqual(viewModel.statusMessage, "已取消下载")
    }

    @MainActor
    func testDownloadFailureOffersRecipeWebsiteForManualDownload() async throws {
        let app = AppRecord(
            id: "com.colliderli.iina",
            name: "IINA",
            bundleIdentifier: "com.colliderli.iina",
            shortVersion: "1.4.3",
            buildVersion: nil,
            path: URL(fileURLWithPath: "/Applications/IINA.app"),
            sizeBytes: 1,
            installSource: .manual(reason: "self"),
            updateStatus: .updateAvailable(installedVersion: "1.4.3", latestVersion: "1.4.4"),
            updateURL: URL(string: "https://dl-portal.iina.io/IINA.v1.4.4.dmg")!,
            updateURLIsDirectDownload: true
        )
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }
        let viewModel = AppListViewModel(
            fileManager: .default,
            downloadsDirectory: temporaryDirectory,
            downloadData: { _, _ in
                throw URLError(.timedOut)
            }
        )

        await viewModel.update(app) { _ in
            XCTFail("Direct download should not open the update URL")
        }

        XCTAssertNil(viewModel.errorMessage)
        XCTAssertEqual(viewModel.downloadFailurePrompt?.appName, "IINA")
        XCTAssertEqual(viewModel.downloadFailurePrompt?.websiteURL, URL(string: "https://iina.io/"))
        XCTAssertTrue(viewModel.downloadFailurePrompt?.message.hasPrefix("下载失败：") == true)
    }

    @MainActor
    func testOpeningDownloadFailureWebsiteClearsPrompt() async throws {
        let app = AppRecord(
            id: "com.colliderli.iina",
            name: "IINA",
            bundleIdentifier: "com.colliderli.iina",
            shortVersion: "1.4.3",
            buildVersion: nil,
            path: URL(fileURLWithPath: "/Applications/IINA.app"),
            sizeBytes: 1,
            installSource: .manual(reason: "self"),
            updateStatus: .updateAvailable(installedVersion: "1.4.3", latestVersion: "1.4.4"),
            updateURL: URL(string: "https://dl-portal.iina.io/IINA.v1.4.4.dmg")!,
            updateURLIsDirectDownload: true
        )
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }
        let viewModel = AppListViewModel(
            fileManager: .default,
            downloadsDirectory: temporaryDirectory,
            downloadData: { _, _ in
                throw URLError(.cannotConnectToHost)
            }
        )
        await viewModel.update(app) { _ in }
        var openedURL: URL?

        viewModel.openDownloadFailureWebsite { url in
            openedURL = url
        }

        XCTAssertEqual(openedURL, URL(string: "https://iina.io/"))
        XCTAssertNil(viewModel.downloadFailurePrompt)
    }

    @MainActor
    func testWebUpdateOpensURLWithoutDownloadProgressStep() async {
        let updateURL = URL(string: "https://example.com/download")!
        let app = AppRecord(
            id: "com.example.web",
            name: "Web",
            bundleIdentifier: "com.example.web",
            shortVersion: "1.0",
            buildVersion: nil,
            path: URL(fileURLWithPath: "/Applications/Web.app"),
            sizeBytes: 1,
            installSource: .manual(reason: "self"),
            updateStatus: .updateAvailable(installedVersion: "1.0", latestVersion: "2.0"),
            updateURL: updateURL,
            updateURLIsDirectDownload: false
        )
        let viewModel = AppListViewModel(downloadData: { _, _ in
            XCTFail("Web update URLs should be opened, not downloaded")
            return Data()
        })
        var openedURL: URL?

        await viewModel.update(app) { url in
            openedURL = url
        }

        XCTAssertEqual(openedURL, updateURL)
        XCTAssertNil(viewModel.updateProgressText)
    }

    @MainActor
    func testHomebrewUpdateOnlyRefreshesHomebrewApps() async {
        var brewApp = makeManualApp(id: "brew")
        brewApp.installSource = .homebrewCask(token: "brew")
        brewApp.updateStatus = .updateAvailable(installedVersion: "1.0", latestVersion: "2.0")
        var manualApp = makeManualApp(id: "manual")
        manualApp.updateStatus = .updateAvailable(installedVersion: "3.0", latestVersion: "4.0")
        manualApp.updateURL = URL(string: "https://example.com/manual.zip")
        manualApp.updateURLIsDirectDownload = true
        let checker = HomebrewOnlyRecordingUpdateChecker()
        let updater = HomebrewCaskUpdater(commandRunner: SuccessfulCommandRunner())
        let viewModel = AppListViewModel(
            updateChecker: checker,
            appCache: AppRecordCache(cacheURL: temporaryCacheURL(), fileManager: .default),
            homebrewUpdater: updater
        )
        viewModel.replaceAppsForTesting([brewApp, manualApp])

        await viewModel.update(brewApp) { _ in }

        XCTAssertEqual(checker.checkedAppIDs, [brewApp.id])
        XCTAssertEqual(viewModel.apps[0].updateStatus, AppUpdateStatus.upToDate)
        XCTAssertEqual(viewModel.apps[1], manualApp)
        XCTAssertEqual(viewModel.statusMessage, "brew 已更新")
    }
}

@MainActor
private final class ViewModelBox {
    var viewModel: AppListViewModel?
}

private final class StepwiseUpdateChecker: AppUpdateChecking, @unchecked Sendable {
    private let lock = NSLock()
    private var continuations: [CheckedContinuation<Void, Never>] = []
    private var startedContinuations: [(Int, CheckedContinuation<Void, Never>)] = []
    private var startedCount = 0
    private var pendingFinishes = 0

    func checkUpdates(for apps: [AppRecord]) throws -> [AppRecord] {
        try checkUpdates(for: apps, onProgress: { _ in })
    }

    func checkUpdates(
        for apps: [AppRecord],
        onProgress: @escaping @Sendable (AppRecord) -> Void
    ) throws -> [AppRecord] {
        lock.lock()
        startedCount += apps.count
        let readyContinuations = startedContinuations.filter { startedCount >= $0.0 }.map(\.1)
        startedContinuations.removeAll { startedCount >= $0.0 }
        lock.unlock()

        for continuation in readyContinuations {
            continuation.resume()
        }

        return apps.map { app in
            waitForFinishSignal()
            var updatedApp = app
            updatedApp.updateStatus = .upToDate
            onProgress(updatedApp)
            return updatedApp
        }
    }

    func waitUntilStarted(count: Int) async {
        await withCheckedContinuation { continuation in
            lock.lock()
            if startedCount >= count {
                lock.unlock()
                continuation.resume()
            } else {
                startedContinuations.append((count, continuation))
                lock.unlock()
            }
        }
    }

    func finishNext() {
        let continuation: CheckedContinuation<Void, Never>?
        lock.lock()
        if continuations.isEmpty {
            pendingFinishes += 1
            continuation = nil
        } else {
            continuation = continuations.removeFirst()
        }
        lock.unlock()
        continuation?.resume()
    }

    private func waitForFinishSignal() {
        lock.lock()
        if pendingFinishes > 0 {
            pendingFinishes -= 1
            lock.unlock()
            return
        }
        lock.unlock()

        let semaphore = DispatchSemaphore(value: 0)
        Task {
            await withCheckedContinuation { continuation in
                lock.lock()
                if pendingFinishes > 0 {
                    pendingFinishes -= 1
                    lock.unlock()
                    continuation.resume()
                } else {
                    continuations.append(continuation)
                    lock.unlock()
                }
            }
            semaphore.signal()
        }
        semaphore.wait()
    }
}

private final class BatchRecordingUpdateChecker: AppUpdateChecking, @unchecked Sendable {
    private let lock = NSLock()
    private var recordedBatchSizes: [Int] = []

    var batchSizes: [Int] {
        lock.lock()
        defer { lock.unlock() }
        return recordedBatchSizes
    }

    func checkUpdates(for apps: [AppRecord]) throws -> [AppRecord] {
        try checkUpdates(for: apps, onProgress: { _ in })
    }

    func checkUpdates(
        for apps: [AppRecord],
        onProgress: @escaping @Sendable (AppRecord) -> Void
    ) throws -> [AppRecord] {
        lock.lock()
        recordedBatchSizes.append(apps.count)
        lock.unlock()

        return apps.map { app in
            var updatedApp = app
            updatedApp.updateStatus = .upToDate
            onProgress(updatedApp)
            return updatedApp
        }
    }
}

private struct FailingResultUpdateChecker: AppUpdateChecking {
    func checkUpdates(for apps: [AppRecord]) throws -> [AppRecord] {
        try checkUpdates(for: apps, onProgress: { _ in })
    }

    func checkUpdates(
        for apps: [AppRecord],
        onProgress: @escaping @Sendable (AppRecord) -> Void
    ) throws -> [AppRecord] {
        apps.map { app in
            var failedApp = app
            failedApp.updateStatus = .checkFailed(message: "The request timed out.")
            failedApp.updateURL = URL(string: "https://example.com/check")
            failedApp.updateURLIsDirectDownload = false
            onProgress(failedApp)
            return failedApp
        }
    }
}

private final class HomebrewOnlyRecordingUpdateChecker: AppUpdateChecking, @unchecked Sendable {
    private let lock = NSLock()
    private var recordedAppIDs: [AppRecord.ID] = []

    var checkedAppIDs: [AppRecord.ID] {
        lock.lock()
        defer { lock.unlock() }
        return recordedAppIDs
    }

    func checkUpdates(for apps: [AppRecord]) throws -> [AppRecord] {
        lock.lock()
        recordedAppIDs.append(contentsOf: apps.map(\.id))
        lock.unlock()
        return apps.map { app in
            var checkedApp = app
            checkedApp.updateStatus = .upToDate
            return checkedApp
        }
    }
}

private struct SuccessfulCommandRunner: CommandRunning {
    func run(_ executable: String, arguments: [String]) throws -> String {
        ""
    }
}

private actor AsyncSignal {
    private var didSignal = false
    private var continuations: [CheckedContinuation<Void, Never>] = []

    func signal() {
        didSignal = true
        let continuations = continuations
        self.continuations.removeAll()
        for continuation in continuations {
            continuation.resume()
        }
    }

    func wait() async {
        if didSignal {
            return
        }
        await withCheckedContinuation { continuation in
            continuations.append(continuation)
        }
    }
}

private struct StubDownloadedAppInstaller: DownloadedAppInstalling {
    let result: DownloadedAppInstallResult
    let beforeReturning: @Sendable (URL, AppRecord) throws -> Void

    init(
        result: DownloadedAppInstallResult,
        beforeReturning: @escaping @Sendable (URL, AppRecord) throws -> Void = { _, _ in }
    ) {
        self.result = result
        self.beforeReturning = beforeReturning
    }

    func install(
        packageURL: URL,
        replacing app: AppRecord,
        progress: @escaping @Sendable (DownloadedAppInstallProgress) -> Void
    ) throws -> DownloadedAppInstallResult {
        try beforeReturning(packageURL, app)
        return result
    }
}

private func makeTestAppBundle(
    at url: URL,
    version: String,
    replaceExisting: Bool = false
) throws {
    if replaceExisting, FileManager.default.fileExists(atPath: url.path) {
        try FileManager.default.removeItem(at: url)
    }
    let contentsURL = url.appendingPathComponent("Contents", isDirectory: true)
    try FileManager.default.createDirectory(at: contentsURL, withIntermediateDirectories: true)
    let plist: [String: Any] = [
        "CFBundleName": "direct",
        "CFBundleIdentifier": "com.example.direct",
        "CFBundleShortVersionString": version,
        "CFBundleVersion": version,
    ]
    let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
    try data.write(to: contentsURL.appendingPathComponent("Info.plist"))
}

private func makeManualApp(
    id: String,
    path: URL? = nil
) -> AppRecord {
    AppRecord(
        id: "com.example.\(id)",
        name: id,
        bundleIdentifier: "com.example.\(id)",
        shortVersion: "1.0",
        buildVersion: nil,
        path: path ?? URL(fileURLWithPath: "/Applications/\(id).app"),
        sizeBytes: 1,
        installSource: .manual(reason: "self")
    )
}

private func temporaryAppBundleURL(name: String) -> URL {
    FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
        .appendingPathComponent("\(name).app", isDirectory: true)
}

private func temporaryCacheURL() -> URL {
    FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString)
        .appendingPathExtension("json")
}

@MainActor
private func waitUntil(
    timeout: TimeInterval = 1,
    condition: @escaping () -> Bool
) async {
    let deadline = Date().addingTimeInterval(timeout)
    while !condition(), Date() < deadline {
        try? await Task.sleep(nanoseconds: 10_000_000)
    }
}
