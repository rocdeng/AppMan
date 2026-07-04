import Foundation

public struct AppPreferences: Equatable, Sendable, Codable {
    public var automaticallyChecksUpdatesOnLaunch: Bool
    public var tinyFishAPIKey: String

    public init(
        automaticallyChecksUpdatesOnLaunch: Bool = false,
        tinyFishAPIKey: String = ""
    ) {
        self.automaticallyChecksUpdatesOnLaunch = automaticallyChecksUpdatesOnLaunch
        self.tinyFishAPIKey = tinyFishAPIKey
    }
}

public struct AppPreferencesStore: @unchecked Sendable {
    private let storeURL: URL
    private let fileManager: FileManager

    public init(
        storeURL: URL = AppPreferencesStore.defaultStoreURL(),
        fileManager: FileManager = .default
    ) {
        self.storeURL = storeURL
        self.fileManager = fileManager
    }

    public func load() throws -> AppPreferences {
        guard fileManager.fileExists(atPath: storeURL.path) else {
            return AppPreferences()
        }

        let data = try Data(contentsOf: storeURL)
        return (try? JSONDecoder().decode(AppPreferences.self, from: data)) ?? AppPreferences()
    }

    public func save(_ preferences: AppPreferences) throws {
        let directoryURL = storeURL.deletingLastPathComponent()
        try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(preferences)
        try data.write(to: storeURL, options: [.atomic])
    }

    public static func defaultStoreURL() -> URL {
        AppManSupportDirectory.url()
            .appendingPathComponent("preferences.json")
    }
}
