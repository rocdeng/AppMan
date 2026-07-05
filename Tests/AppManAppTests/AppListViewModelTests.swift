import XCTest
@testable import AppManApp
import AppManCore

final class AppListViewModelTests: XCTestCase {
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
