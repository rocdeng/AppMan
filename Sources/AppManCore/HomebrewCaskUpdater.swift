import Foundation

public struct HomebrewCaskUpdater: Sendable {
    private let commandRunner: any CommandRunning

    public init(commandRunner: any CommandRunning = ProcessCommandRunner()) {
        self.commandRunner = commandRunner
    }

    public func update(token: String) throws {
        var refreshError: Error?
        do {
            _ = try commandRunner.run("brew", arguments: ["update", "--quiet"])
        } catch {
            refreshError = error
        }

        do {
            _ = try commandRunner.run("brew", arguments: ["upgrade", "--cask", token])
        } catch {
            if let refreshError {
                throw HomebrewCaskUpdateError.refreshAndUpgradeFailed(
                    refresh: refreshError,
                    upgrade: error
                )
            }
            throw error
        }
    }
}

public enum HomebrewCaskUpdateError: LocalizedError, Equatable {
    case refreshAndUpgradeFailed(refresh: Error, upgrade: Error)

    public static func == (lhs: HomebrewCaskUpdateError, rhs: HomebrewCaskUpdateError) -> Bool {
        lhs.localizedDescription == rhs.localizedDescription
    }

    public var errorDescription: String? {
        switch self {
        case let .refreshAndUpgradeFailed(refresh, upgrade):
            return "Homebrew 刷新失败：\(refresh.localizedDescription)\nHomebrew 升级失败：\(upgrade.localizedDescription)"
        }
    }
}

public enum HomebrewErrorFormatter {
    public static func userFacingMessage(from error: Error) -> String {
        let details: String
        if let combinedError = error as? HomebrewCaskUpdateError {
            details = combinedError.localizedDescription
                .components(separatedBy: .newlines)
                .map { userFacingDetail(from: $0) }
                .filter { !$0.isEmpty }
                .joined(separator: "\n")
        } else {
            details = userFacingDetail(from: error.localizedDescription)
        }

        guard !details.isEmpty else {
            return "Homebrew 更新失败"
        }
        return "Homebrew 更新失败\n\n\(details.prefix(1200))"
    }

    private static func userFacingDetail(from text: String) -> String {
        let lines = text.components(separatedBy: .newlines).map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let errorLines = lines.filter { line in
            line.hasPrefix("Error:") || line.localizedCaseInsensitiveContains("failed to")
        }
        if !errorLines.isEmpty {
            return errorLines.joined(separator: "\n")
        }

        return lines
            .filter { !$0.isEmpty && !$0.hasPrefix("==>") }
            .suffix(3)
            .joined(separator: "\n")
    }
}
