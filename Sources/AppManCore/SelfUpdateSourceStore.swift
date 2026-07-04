import Foundation

public struct SelfUpdateSourceRecord: Equatable, Sendable, Codable, Identifiable {
    public let id: String
    public let name: String
    public let bundleIdentifier: String?
    public let updateURL: URL
    public let confirmedAt: Date

    public init(
        id: String,
        name: String,
        bundleIdentifier: String?,
        updateURL: URL,
        confirmedAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.bundleIdentifier = bundleIdentifier
        self.updateURL = updateURL
        self.confirmedAt = confirmedAt
    }

    public init(app: AppRecord, updateURL: URL, confirmedAt: Date = Date()) {
        self.init(
            id: app.id,
            name: app.name,
            bundleIdentifier: app.bundleIdentifier,
            updateURL: updateURL,
            confirmedAt: confirmedAt
        )
    }
}

public struct SelfUpdateSourceStore: @unchecked Sendable {
    private let storeURL: URL
    private let fileManager: FileManager

    public init(
        storeURL: URL = SelfUpdateSourceStore.defaultStoreURL(),
        fileManager: FileManager = .default
    ) {
        self.storeURL = storeURL
        self.fileManager = fileManager
    }

    public func load() throws -> [SelfUpdateSourceRecord] {
        guard fileManager.fileExists(atPath: storeURL.path) else {
            return []
        }

        let data = try Data(contentsOf: storeURL)
        return (try? JSONDecoder().decode([SelfUpdateSourceRecord].self, from: data)) ?? []
    }

    public func record(for app: AppRecord) throws -> SelfUpdateSourceRecord? {
        let records = try load()
        if let record = records.first(where: { $0.id == app.id }) {
            return record
        }

        guard let bundleIdentifier = app.bundleIdentifier else {
            return nil
        }
        return records.first { $0.bundleIdentifier == bundleIdentifier }
    }

    public func save(_ record: SelfUpdateSourceRecord) throws {
        var records = try load()
        records.removeAll { existing in
            existing.id == record.id || (
                record.bundleIdentifier != nil
                    && existing.bundleIdentifier == record.bundleIdentifier
            )
        }
        records.append(record)
        records.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        try save(records)
    }

    private func save(_ records: [SelfUpdateSourceRecord]) throws {
        let directoryURL = storeURL.deletingLastPathComponent()
        try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(records)
        try data.write(to: storeURL, options: [.atomic])
    }

    public static func defaultStoreURL() -> URL {
        AppManSupportDirectory.url()
            .appendingPathComponent("self-update-sources.json")
    }
}
