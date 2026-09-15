import XCTest
@testable import AppManCore

final class HomebrewCaskUpdaterTests: XCTestCase {
    func testUpdatesHomebrewCaskByRefreshingThenUpgradingToken() throws {
        let runner = RecordingCommandRunner()
        let updater = HomebrewCaskUpdater(commandRunner: runner)

        try updater.update(token: "visual-studio-code")

        XCTAssertEqual(runner.commands, [
            ["brew", "update", "--quiet"],
            ["brew", "upgrade", "--cask", "visual-studio-code"],
        ])
    }

    func testAttemptsCaskUpgradeWhenHomebrewRefreshFails() throws {
        let runner = RecordingCommandRunner(errors: [
            ["brew", "update", "--quiet"]: CommandError.failed(status: 1, stderr: "Error: API unavailable")
        ])
        let updater = HomebrewCaskUpdater(commandRunner: runner)

        try updater.update(token: "tablepro")

        XCTAssertEqual(runner.commands, [
            ["brew", "update", "--quiet"],
            ["brew", "upgrade", "--cask", "tablepro"],
        ])
    }

    func testFormatsOnlyActionableHomebrewErrors() {
        let error = CommandError.failed(
            status: 1,
            stderr: """
            ==> New Formulae
            a-normal-formula
            ==> New Casks
            another-cask
            Error: Failed to download https://formulae.brew.sh/api/internal/packages.arm64_golden_gate.jws.json!
            ==> Outdated Formulae
            lots-of-normal-update-output
            """
        )

        let message = HomebrewErrorFormatter.userFacingMessage(from: error)

        XCTAssertTrue(message.contains("Failed to download"))
        XCTAssertFalse(message.contains("New Formulae"))
        XCTAssertFalse(message.contains("New Casks"))
        XCTAssertFalse(message.contains("Outdated Formulae"))
    }
}

private final class RecordingCommandRunner: CommandRunning, @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [[String]] = []
    private let errors: [[String]: Error]

    init(errors: [[String]: Error] = [:]) {
        self.errors = errors
    }

    var commands: [[String]] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func run(_ executable: String, arguments: [String]) throws -> String {
        lock.lock()
        storage.append([executable] + arguments)
        lock.unlock()
        if let error = errors[[executable] + arguments] {
            throw error
        }
        return ""
    }
}
