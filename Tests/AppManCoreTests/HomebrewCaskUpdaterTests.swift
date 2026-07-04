import XCTest
@testable import AppManCore

final class HomebrewCaskUpdaterTests: XCTestCase {
    func testUpdatesHomebrewCaskByRefreshingThenUpgradingToken() throws {
        let runner = RecordingCommandRunner()
        let updater = HomebrewCaskUpdater(commandRunner: runner)

        try updater.update(token: "visual-studio-code")

        XCTAssertEqual(runner.commands, [
            ["brew", "update"],
            ["brew", "upgrade", "--cask", "visual-studio-code"],
        ])
    }
}

private final class RecordingCommandRunner: CommandRunning, @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [[String]] = []

    var commands: [[String]] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func run(_ executable: String, arguments: [String]) throws -> String {
        lock.lock()
        storage.append([executable] + arguments)
        lock.unlock()
        return ""
    }
}
