import XCTest
@testable import AppManCore

final class HomebrewCaskUpdateCheckerTests: XCTestCase {
    func testMarksHomebrewCaskAsUpdateAvailable() throws {
        let checker = HomebrewCaskUpdateChecker(commandRunner: StubUpdateCommandRunner(output: """
        {
          "formulae": [],
          "casks": [
            {
              "name": "codex",
              "installed_versions": ["0.141.0"],
              "current_version": "0.142.1",
              "pinned": false,
              "pinned_version": null
            }
          ]
        }
        """))
        let app = makeApp(installSource: .homebrewCask(token: "codex"))

        let apps = try checker.checkUpdates(for: [app])

        XCTAssertEqual(
            apps.first?.updateStatus,
            .updateAvailable(installedVersion: "0.141.0", latestVersion: "0.142.1")
        )
    }

    func testExtractsJSONAfterHomebrewAutoUpdateOutput() throws {
        let checker = HomebrewCaskUpdateChecker(commandRunner: StubUpdateCommandRunner(output: """
        ==> Auto-updating Homebrew...
        You have 1 outdated cask installed.

        {
          "formulae": [],
          "casks": [
            {
              "name": "tablepro",
              "installed_versions": ["0.52.0"],
              "current_version": "0.52.1"
            }
          ]
        }
        """))
        let app = makeApp(installSource: .homebrewCask(token: "tablepro"))

        let apps = try checker.checkUpdates(for: [app])

        XCTAssertEqual(
            apps.first?.updateStatus,
            .updateAvailable(installedVersion: "0.52.0", latestVersion: "0.52.1")
        )
    }

    func testMarksHomebrewCaskAsUpToDateWhenNotOutdated() throws {
        let checker = HomebrewCaskUpdateChecker(commandRunner: StubUpdateCommandRunner(output: """
        {
          "casks": []
        }
        """))
        let app = makeApp(installSource: .homebrewCask(token: "codex"))

        let apps = try checker.checkUpdates(for: [app])

        XCTAssertEqual(apps.first?.updateStatus, .upToDate)
    }

    func testMarksNonHomebrewAppsAsUnsupportedWithoutCallingBrew() throws {
        let runner = CountingUpdateCommandRunner(output: "{}")
        let checker = HomebrewCaskUpdateChecker(commandRunner: runner)
        let app = makeApp(installSource: .macAppStore)

        let apps = try checker.checkUpdates(for: [app])

        XCTAssertEqual(apps.first?.updateStatus, .unsupported(reason: "暂不支持此安装渠道"))
        XCTAssertEqual(runner.runCallCount, 0)
    }

    func testMarksHomebrewAppsAsFailedWhenBrewIsUnavailable() throws {
        let checker = HomebrewCaskUpdateChecker(
            commandRunner: StubUpdateCommandRunner(error: .executableNotFound("brew"))
        )
        let app = makeApp(installSource: .homebrewCask(token: "codex"))

        let apps = try checker.checkUpdates(for: [app])

        XCTAssertEqual(apps.first?.updateStatus, .checkFailed(message: "Homebrew 不可用"))
    }

    private func makeApp(installSource: InstallSource) -> AppRecord {
        AppRecord(
            id: UUID().uuidString,
            name: "Test",
            bundleIdentifier: "com.example.test",
            shortVersion: "1.0",
            buildVersion: nil,
            path: URL(fileURLWithPath: "/Applications/Test.app"),
            sizeBytes: 1,
            installSource: installSource
        )
    }
}

private struct StubUpdateCommandRunner: CommandRunning {
    let output: String
    let error: CommandError?

    init(output: String = "", error: CommandError? = nil) {
        self.output = output
        self.error = error
    }

    func run(_ executable: String, arguments: [String]) throws -> String {
        XCTAssertEqual(executable, "brew")
        XCTAssertEqual(arguments, ["outdated", "--cask", "--json=v2"])
        if let error {
            throw error
        }
        return output
    }
}

private final class CountingUpdateCommandRunner: CommandRunning, @unchecked Sendable {
    private let output: String
    private(set) var runCallCount = 0

    init(output: String) {
        self.output = output
    }

    func run(_ executable: String, arguments: [String]) throws -> String {
        runCallCount += 1
        return output
    }
}
