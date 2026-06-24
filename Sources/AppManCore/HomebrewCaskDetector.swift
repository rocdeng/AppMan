import Foundation

public struct HomebrewCaskDetector: Sendable {
    private let commandRunner: any CommandRunning

    public init(commandRunner: any CommandRunning = ProcessCommandRunner()) {
        self.commandRunner = commandRunner
    }

    public func detectInstallSource(for app: AppRecord) throws -> InstallSource? {
        let output: String
        do {
            output = try commandRunner.run("brew", arguments: ["info", "--cask", "--json=v2"])
        } catch CommandError.executableNotFound("brew") {
            return nil
        }

        let data = Data(output.utf8)
        let response = try JSONDecoder().decode(BrewInfoResponse.self, from: data)
        let appName = app.path.lastPathComponent

        for cask in response.casks {
            for artifact in cask.artifacts {
                guard let artifactAppName = artifact.appName else {
                    continue
                }
                if artifactAppName == appName {
                    return .homebrewCask(token: cask.token)
                }
            }
        }

        return nil
    }
}

private struct BrewInfoResponse: Decodable {
    let casks: [Cask]
}

private struct Cask: Decodable {
    let token: String
    let artifacts: [Artifact]
}

private struct Artifact: Decodable {
    let appName: String?

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        appName = try container.decodeIfPresent(AppArtifact.self, forKey: .app)?.name
    }

    private enum CodingKeys: String, CodingKey {
        case app
    }
}

private struct AppArtifact: Decodable {
    let name: String

    init(from decoder: Decoder) throws {
        var container = try decoder.unkeyedContainer()
        name = try container.decode(String.self)
    }
}
