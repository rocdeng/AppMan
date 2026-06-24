import Foundation

public protocol HomebrewDetecting: Sendable {
    func detectInstallSource(for app: AppRecord) throws -> InstallSource?
}

public struct HomebrewCaskDetector: HomebrewDetecting {
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

        guard !output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }

        let data = Data(output.utf8)
        let response = try JSONDecoder().decode(BrewInfoResponse.self, from: data)
        let appName = app.path.lastPathComponent

        for cask in response.casks {
            for artifact in cask.artifacts {
                if artifact.appNames.contains(appName) {
                    return .homebrewCask(token: cask.token)
                }
            }
        }

        return nil
    }
}

private struct BrewInfoResponse: Decodable {
    let casks: [Cask]

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        casks = try container.decodeIfPresent([Cask].self, forKey: .casks) ?? []
    }

    private enum CodingKeys: String, CodingKey {
        case casks
    }
}

private struct Cask: Decodable {
    let token: String
    let artifacts: [Artifact]

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        token = try container.decode(String.self, forKey: .token)
        artifacts = try container.decodeIfPresent(LossyArtifacts.self, forKey: .artifacts)?.values ?? []
    }

    private enum CodingKeys: String, CodingKey {
        case token
        case artifacts
    }
}

private struct Artifact: Decodable {
    let appNames: [String]

    init(from decoder: Decoder) throws {
        guard let container = try? decoder.container(keyedBy: CodingKeys.self) else {
            appNames = []
            return
        }
        appNames = (try container.decodeIfPresent(AppArtifact.self, forKey: .app))?.names ?? []
    }

    private enum CodingKeys: String, CodingKey {
        case app
    }
}

private struct AppArtifact: Decodable {
    let names: [String]

    init(from decoder: Decoder) throws {
        var container = try decoder.unkeyedContainer()
        var names: [String] = []
        while !container.isAtEnd {
            if let name = try? container.decode(String.self) {
                names.append(name)
            } else {
                _ = try? container.decode(DiscardedJSONValue.self)
            }
        }
        self.names = names
    }
}

private struct LossyArtifacts: Decodable {
    let values: [Artifact]

    init(from decoder: Decoder) throws {
        var container = try decoder.unkeyedContainer()
        var values: [Artifact] = []
        while !container.isAtEnd {
            if let artifact = try? container.decode(Artifact.self) {
                values.append(artifact)
            } else {
                _ = try? container.decode(DiscardedJSONValue.self)
            }
        }
        self.values = values
    }
}

private struct DiscardedJSONValue: Decodable {
    init(from decoder: Decoder) throws {
        if var array = try? decoder.unkeyedContainer() {
            while !array.isAtEnd {
                _ = try? array.decode(DiscardedJSONValue.self)
            }
            return
        }

        if let object = try? decoder.container(keyedBy: DynamicCodingKey.self) {
            for key in object.allKeys {
                _ = try? object.decode(DiscardedJSONValue.self, forKey: key)
            }
            return
        }

        let singleValue = try decoder.singleValueContainer()
        if singleValue.decodeNil() {
            return
        }
        if (try? singleValue.decode(Bool.self)) != nil {
            return
        }
        if (try? singleValue.decode(Double.self)) != nil {
            return
        }
        _ = try? singleValue.decode(String.self)
    }
}

private struct DynamicCodingKey: CodingKey {
    let stringValue: String
    let intValue: Int?

    init?(stringValue: String) {
        self.stringValue = stringValue
        intValue = nil
    }

    init?(intValue: Int) {
        stringValue = String(intValue)
        self.intValue = intValue
    }
}
