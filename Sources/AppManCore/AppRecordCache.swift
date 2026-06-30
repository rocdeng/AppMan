import Foundation

public struct AppRecordCache: @unchecked Sendable {
    private static let schemaVersion = 2

    private let cacheURL: URL
    private let fileManager: FileManager

    public init(
        cacheURL: URL = AppRecordCache.defaultCacheURL(),
        fileManager: FileManager = .default
    ) {
        self.cacheURL = cacheURL
        self.fileManager = fileManager
    }

    public func load() throws -> [AppRecord] {
        guard fileManager.fileExists(atPath: cacheURL.path) else {
            return []
        }

        let data = try Data(contentsOf: cacheURL)
        guard let payload = try? JSONDecoder().decode(CachePayload.self, from: data) else {
            return []
        }
        guard payload.schemaVersion == Self.schemaVersion else {
            return []
        }
        return payload.apps
    }

    public func save(_ apps: [AppRecord]) throws {
        let directoryURL = cacheURL.deletingLastPathComponent()
        try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(CachePayload(schemaVersion: Self.schemaVersion, apps: apps))
        try data.write(to: cacheURL, options: [.atomic])
    }

    public static func defaultCacheURL() -> URL {
        let baseURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first ?? FileManager.default.homeDirectoryForCurrentUser
        return baseURL
            .appendingPathComponent("AppMan", isDirectory: true)
            .appendingPathComponent("apps-cache.json")
    }
}

private struct CachePayload: Codable {
    let schemaVersion: Int
    let apps: [AppRecord]
}
