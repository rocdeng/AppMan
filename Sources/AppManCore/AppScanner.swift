import Foundation

public struct AppScanner: @unchecked Sendable {
    private let scanRoots: [URL]
    private let fileManager: FileManager
    private let bundleReader: AppBundleReader

    public init(
        scanRoots: [URL] = AppScanner.defaultScanRoots(),
        fileManager: FileManager = .default,
        bundleReader: AppBundleReader = AppBundleReader()
    ) {
        self.scanRoots = scanRoots
        self.fileManager = fileManager
        self.bundleReader = bundleReader
    }

    public func scanInstalledApps() throws -> [AppRecord] {
        var records: [AppRecord] = []

        for root in scanRoots {
            guard fileManager.fileExists(atPath: root.path) else {
                continue
            }

            let children = try fileManager.contentsOfDirectory(
                at: root,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            )

            for child in children where child.pathExtension == "app" {
                guard (try? child.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else {
                    continue
                }

                if let record = try? bundleReader.readApp(at: child) {
                    records.append(record)
                }
            }
        }

        return Self.deduplicated(records).sorted { left, right in
            let nameOrder = left.name.localizedCaseInsensitiveCompare(right.name)
            if nameOrder != .orderedSame {
                return nameOrder == .orderedAscending
            }

            let leftTieBreaker = left.bundleIdentifier ?? left.path.path
            let rightTieBreaker = right.bundleIdentifier ?? right.path.path
            let tieBreakerOrder = leftTieBreaker.localizedCaseInsensitiveCompare(rightTieBreaker)
            if tieBreakerOrder != .orderedSame {
                return tieBreakerOrder == .orderedAscending
            }

            return left.path.path.localizedCaseInsensitiveCompare(right.path.path) == .orderedAscending
        }
    }

    public static func deduplicated(_ records: [AppRecord]) -> [AppRecord] {
        var deduplicatedRecords: [AppRecord] = []
        var indexByBundleIdentifier: [String: Int] = [:]

        for record in records {
            guard let bundleIdentifier = record.bundleIdentifier?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased(),
                  !bundleIdentifier.isEmpty else {
                deduplicatedRecords.append(record)
                continue
            }

            if let existingIndex = indexByBundleIdentifier[bundleIdentifier] {
                if preferredLocationRank(for: record.path) < preferredLocationRank(for: deduplicatedRecords[existingIndex].path) {
                    deduplicatedRecords[existingIndex] = record
                }
                continue
            }

            indexByBundleIdentifier[bundleIdentifier] = deduplicatedRecords.count
            deduplicatedRecords.append(record)
        }

        return deduplicatedRecords
    }

    private static func preferredLocationRank(for url: URL) -> Int {
        let path = url.standardizedFileURL.path
        if path == "/Applications" || path.hasPrefix("/Applications/") {
            return 0
        }

        let userApplicationsPath = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Applications", isDirectory: true)
            .standardizedFileURL.path
        if path == userApplicationsPath || path.hasPrefix(userApplicationsPath + "/") {
            return 1
        }

        return 2
    }

    public static func defaultScanRoots() -> [URL] {
        var roots = [URL(fileURLWithPath: "/Applications", isDirectory: true)]
        if let userApplications = FileManager.default.urls(for: .applicationDirectory, in: .userDomainMask).first {
            roots.append(userApplications)
        }
        return roots
    }
}
