import XCTest
@testable import AppManCore

final class CompositeAppUpdateCheckerTests: XCTestCase {
    func testDispatchesAppsByInstallSourceAndPreservesOriginalOrder() throws {
        let checker = CompositeAppUpdateChecker(
            homebrewChecker: SourceMarkingChecker(status: .upToDate),
            macAppStoreChecker: SourceMarkingChecker(status: .updateAvailable(installedVersion: "1.0", latestVersion: "1.1")),
            sparkleChecker: SourceMarkingChecker(status: .checkFailed(message: "feed failed")),
            selfHostedChecker: SourceMarkingChecker(status: .needsManualUpdateURL)
        )
        let apps = [
            makeApp(id: "manual", source: .manual(reason: "unknown")),
            makeApp(id: "brew", source: .homebrewCask(token: "test")),
            makeApp(id: "mas", source: .macAppStore),
            makeApp(id: "sparkle", source: .sparkle(feedURL: URL(string: "https://example.com/appcast.xml")!)),
        ]

        let updatedApps = try checker.checkUpdates(for: apps)

        XCTAssertEqual(updatedApps.map(\.id), ["manual", "brew", "mas", "sparkle"])
        XCTAssertEqual(
            updatedApps.map(\.updateStatus),
            [
                .needsManualUpdateURL,
                .upToDate,
                .updateAvailable(installedVersion: "1.0", latestVersion: "1.1"),
                .checkFailed(message: "feed failed"),
            ]
        )
    }

    func testLeavesIgnoredAppsUntouched() throws {
        let checker = CompositeAppUpdateChecker(
            homebrewChecker: SourceMarkingChecker(status: .upToDate),
            macAppStoreChecker: SourceMarkingChecker(status: .upToDate),
            sparkleChecker: SourceMarkingChecker(status: .upToDate),
            selfHostedChecker: SourceMarkingChecker(status: .upToDate)
        )
        var app = makeApp(id: "ignored", source: .homebrewCask(token: "ignored"))
        app.updateStatus = .ignored

        let updatedApps = try checker.checkUpdates(for: [app])

        XCTAssertEqual(updatedApps.first?.updateStatus, .ignored)
    }

    func testPreservesSeparateRecordsWhenAppsShareBundleIdentifier() throws {
        let checker = CompositeAppUpdateChecker(
            homebrewChecker: PathMarkingChecker(),
            macAppStoreChecker: SourceMarkingChecker(status: .upToDate),
            sparkleChecker: SourceMarkingChecker(status: .upToDate),
            selfHostedChecker: SourceMarkingChecker(status: .upToDate)
        )
        let apps = [
            makeApp(id: "com.example.shared", path: "/Applications/First.app", source: .homebrewCask(token: "first")),
            makeApp(id: "com.example.shared", path: "/Applications/Second.app", source: .homebrewCask(token: "second")),
        ]

        let updatedApps = try checker.checkUpdates(for: apps)

        XCTAssertEqual(updatedApps.map(\.path.path), ["/Applications/First.app", "/Applications/Second.app"])
        XCTAssertEqual(
            updatedApps.map(\.updateStatus),
            [
                .updateAvailable(installedVersion: "1.0", latestVersion: "First.app"),
                .updateAvailable(installedVersion: "1.0", latestVersion: "Second.app"),
            ]
        )
    }

    func testSlowHomebrewCheckDoesNotBlockOtherSourcesProgress() throws {
        let homebrewGate = DispatchSemaphore(value: 0)
        let homebrewStarted = expectation(description: "Homebrew check started")
        let macAppStoreProgress = expectation(description: "Mac App Store progress reported")
        let checkFinished = expectation(description: "All checks finished")
        let checker = CompositeAppUpdateChecker(
            homebrewChecker: BlockingUpdateChecker(started: homebrewStarted, gate: homebrewGate),
            macAppStoreChecker: SourceMarkingChecker(status: .upToDate),
            sparkleChecker: SourceMarkingChecker(status: .upToDate),
            selfHostedChecker: SourceMarkingChecker(status: .upToDate)
        )
        let apps = [
            makeApp(id: "brew", source: .homebrewCask(token: "test")),
            makeApp(id: "mas", source: .macAppStore),
        ]

        DispatchQueue.global().async {
            _ = try? checker.checkUpdates(for: apps) { app in
                if app.id == "mas" {
                    macAppStoreProgress.fulfill()
                }
            }
            checkFinished.fulfill()
        }

        wait(for: [homebrewStarted, macAppStoreProgress], timeout: 2)
        homebrewGate.signal()
        wait(for: [checkFinished], timeout: 2)
    }

    private func makeApp(
        id: String,
        path: String? = nil,
        source: InstallSource
    ) -> AppRecord {
        AppRecord(
            id: id,
            name: id,
            bundleIdentifier: "com.example.\(id)",
            shortVersion: "1.0",
            buildVersion: nil,
            path: URL(fileURLWithPath: path ?? "/Applications/\(id).app"),
            sizeBytes: 1,
            installSource: source
        )
    }
}

private struct SourceMarkingChecker: AppUpdateChecking {
    let status: AppUpdateStatus

    func checkUpdates(for apps: [AppRecord]) throws -> [AppRecord] {
        apps.map { app in
            var updatedApp = app
            updatedApp.updateStatus = status
            return updatedApp
        }
    }
}

private struct PathMarkingChecker: AppUpdateChecking {
    func checkUpdates(for apps: [AppRecord]) throws -> [AppRecord] {
        apps.map { app in
            var updatedApp = app
            updatedApp.updateStatus = .updateAvailable(
                installedVersion: app.shortVersion,
                latestVersion: app.path.lastPathComponent
            )
            return updatedApp
        }
    }
}

private struct BlockingUpdateChecker: AppUpdateChecking {
    let started: XCTestExpectation
    let gate: DispatchSemaphore

    func checkUpdates(for apps: [AppRecord]) throws -> [AppRecord] {
        started.fulfill()
        gate.wait()
        return apps
    }
}
