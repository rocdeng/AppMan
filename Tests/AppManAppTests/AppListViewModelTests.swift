import XCTest
@testable import AppManApp
import AppManCore

final class AppListViewModelTests: XCTestCase {
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

private func makeManualApp(id: String) -> AppRecord {
    AppRecord(
        id: "com.example.\(id)",
        name: id,
        bundleIdentifier: "com.example.\(id)",
        shortVersion: "1.0",
        buildVersion: nil,
        path: URL(fileURLWithPath: "/Applications/\(id).app"),
        sizeBytes: 1,
        installSource: .manual(reason: "self")
    )
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
