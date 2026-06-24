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

        return records.sorted { left, right in
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

    public static func defaultScanRoots() -> [URL] {
        var roots = [URL(fileURLWithPath: "/Applications", isDirectory: true)]
        if let userApplications = FileManager.default.urls(for: .applicationDirectory, in: .userDomainMask).first {
            roots.append(userApplications)
        }
        return roots
    }
}
