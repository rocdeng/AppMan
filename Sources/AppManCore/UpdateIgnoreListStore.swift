import Foundation

public struct IgnoredAppRecord: Equatable, Sendable, Codable, Identifiable {
    public let id: String
    public let name: String
    public let bundleIdentifier: String?
    public let path: URL
    public let sourceName: String

    public init(
        id: String,
        name: String,
        bundleIdentifier: String?,
        path: URL,
        sourceName: String
    ) {
        self.id = id
        self.name = name
        self.bundleIdentifier = bundleIdentifier
        self.path = path
        self.sourceName = sourceName
    }

    public init(app: AppRecord) {
        self.init(
            id: app.id,
            name: app.name,
            bundleIdentifier: app.bundleIdentifier,
            path: app.path,
            sourceName: app.installSource.shortSourceName
        )
    }
}

public struct UpdateIgnoreListStore: @unchecked Sendable {
    private let storeURL: URL
    private let fileManager: FileManager

    public init(
        storeURL: URL = UpdateIgnoreListStore.defaultStoreURL(),
        fileManager: FileManager = .default
    ) {
        self.storeURL = storeURL
        self.fileManager = fileManager
    }

    public func load() throws -> [IgnoredAppRecord] {
        guard fileManager.fileExists(atPath: storeURL.path) else {
            return []
        }

        let data = try Data(contentsOf: storeURL)
        return (try? JSONDecoder().decode([IgnoredAppRecord].self, from: data)) ?? []
    }

    public func save(_ records: [IgnoredAppRecord]) throws {
        let directoryURL = storeURL.deletingLastPathComponent()
        try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(records)
        try data.write(to: storeURL, options: [.atomic])
    }

    @discardableResult
    public func remove(id: String) throws -> [IgnoredAppRecord] {
        let records = try load().filter { $0.id != id }
        try save(records)
        return records
    }

    @discardableResult
    public func remove(path: URL) throws -> [IgnoredAppRecord] {
        let records = try load().filter { $0.path != path }
        try save(records)
        return records
    }

    public static func defaultStoreURL() -> URL {
        AppManSupportDirectory.url()
            .appendingPathComponent("ignored-updates.json")
    }
}

extension InstallSource {
    var shortSourceName: String {
        switch self {
        case .macAppStore:
            return "MAS"
        case .homebrewCask:
            return "BREW"
        case .sparkle, .manual:
            return "SELF"
        }
    }
}
