import Foundation

public protocol AppUpdateChecking: Sendable {
    func checkUpdates(for apps: [AppRecord]) throws -> [AppRecord]
    func checkUpdates(
        for apps: [AppRecord],
        onProgress: @escaping @Sendable (AppRecord) -> Void
    ) throws -> [AppRecord]
}

public extension AppUpdateChecking {
    func checkUpdates(
        for apps: [AppRecord],
        onProgress: @escaping @Sendable (AppRecord) -> Void
    ) throws -> [AppRecord] {
        let checkedApps = try checkUpdates(for: apps)
        checkedApps.forEach(onProgress)
        return checkedApps
    }
}

public struct HomebrewCaskUpdateChecker: AppUpdateChecking {
    private let commandRunner: any CommandRunning

    public init(commandRunner: any CommandRunning = ProcessCommandRunner()) {
        self.commandRunner = commandRunner
    }

    public func checkUpdates(for apps: [AppRecord]) throws -> [AppRecord] {
        try checkUpdates(for: apps, onProgress: { _ in })
    }

    public func checkUpdates(
        for apps: [AppRecord],
        onProgress: @escaping @Sendable (AppRecord) -> Void
    ) throws -> [AppRecord] {
        let homebrewApps = apps.filter { app in
            if case .homebrewCask = app.installSource {
                return true
            }
            return false
        }

        let outdatedCasks: [String: OutdatedCask]
        let checkFailureMessage: String?
        if homebrewApps.isEmpty {
            outdatedCasks = [:]
            checkFailureMessage = nil
        } else {
            do {
                outdatedCasks = try loadOutdatedCasks()
                checkFailureMessage = nil
            } catch CommandError.executableNotFound("brew") {
                outdatedCasks = [:]
                checkFailureMessage = "Homebrew 不可用"
            } catch {
                outdatedCasks = [:]
                checkFailureMessage = error.localizedDescription
            }
        }

        let updatedApps = apps.map { app in
            var updatedApp = app

            guard case let .homebrewCask(token) = app.installSource else {
                updatedApp.updateStatus = .unsupported(reason: "暂不支持此安装渠道")
                return updatedApp
            }

            updatedApp.updateURL = Self.caskPageURL(for: token)
            updatedApp.updateURLIsDirectDownload = false

            if let checkFailureMessage {
                updatedApp.updateStatus = .checkFailed(message: checkFailureMessage)
                return updatedApp
            }

            if let cask = outdatedCasks[token] {
                updatedApp.updateStatus = .updateAvailable(
                    installedVersion: cask.installedVersions.first,
                    latestVersion: cask.currentVersion
                )
            } else {
                updatedApp.updateStatus = .upToDate
            }

            return updatedApp
        }

        updatedApps.forEach(onProgress)
        return updatedApps
    }

    private static func caskPageURL(for token: String) -> URL? {
        var components = URLComponents()
        components.scheme = "https"
        components.host = "formulae.brew.sh"
        components.path = "/cask/\(token)"
        return components.url
    }

    private func loadOutdatedCasks() throws -> [String: OutdatedCask] {
        let output = try commandRunner.run("brew", arguments: ["outdated", "--cask", "--json=v2"])

        guard let json = extractJSONObject(from: output), let data = json.data(using: .utf8) else {
            return [:]
        }

        let response = try JSONDecoder().decode(BrewOutdatedResponse.self, from: data)
        return Dictionary(uniqueKeysWithValues: response.casks.map { ($0.name, $0) })
    }

    private func extractJSONObject(from output: String) -> String? {
        guard
            let start = output.firstIndex(of: "{"),
            let end = output.lastIndex(of: "}"),
            start <= end
        else {
            return nil
        }

        return String(output[start...end])
    }
}

private struct BrewOutdatedResponse: Decodable {
    let casks: [OutdatedCask]

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        casks = try container.decodeIfPresent([OutdatedCask].self, forKey: .casks) ?? []
    }

    private enum CodingKeys: String, CodingKey {
        case casks
    }
}

private struct OutdatedCask: Decodable {
    let name: String
    let installedVersions: [String]
    let currentVersion: String

    private enum CodingKeys: String, CodingKey {
        case name
        case installedVersions = "installed_versions"
        case currentVersion = "current_version"
    }
}
