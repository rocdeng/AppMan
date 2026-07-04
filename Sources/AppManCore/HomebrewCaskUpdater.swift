import Foundation

public struct HomebrewCaskUpdater: Sendable {
    private let commandRunner: any CommandRunning

    public init(commandRunner: any CommandRunning = ProcessCommandRunner()) {
        self.commandRunner = commandRunner
    }

    public func update(token: String) throws {
        _ = try commandRunner.run("brew", arguments: ["update"])
        _ = try commandRunner.run("brew", arguments: ["upgrade", "--cask", token])
    }
}
