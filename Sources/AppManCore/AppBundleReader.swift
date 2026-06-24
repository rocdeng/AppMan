import Foundation

public enum AppBundleReaderError: Error, Equatable {
    case missingInfoPlist(URL)
    case unreadableInfoPlist(URL)
}

public struct AppBundleReader: @unchecked Sendable {
    private let fileManager: FileManager

    public init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    public func readApp(at appURL: URL) throws -> AppRecord {
        let infoPlistURL = appURL
            .appendingPathComponent("Contents", isDirectory: true)
            .appendingPathComponent("Info.plist")

        guard fileManager.fileExists(atPath: infoPlistURL.path) else {
            throw AppBundleReaderError.missingInfoPlist(infoPlistURL)
        }

        let data = try Data(contentsOf: infoPlistURL)
        guard
            let plist = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        else {
            throw AppBundleReaderError.unreadableInfoPlist(infoPlistURL)
        }

        let displayName = plist["CFBundleDisplayName"] as? String
        let bundleName = plist["CFBundleName"] as? String
        let fallbackName = appURL.deletingPathExtension().lastPathComponent
        let name = displayName ?? bundleName ?? fallbackName

        let bundleIdentifier = plist["CFBundleIdentifier"] as? String
        let shortVersion = plist["CFBundleShortVersionString"] as? String
        let buildVersion = plist["CFBundleVersion"] as? String
        let sizeBytes = directorySize(at: appURL)

        return AppRecord(
            id: bundleIdentifier ?? appURL.path,
            name: name,
            bundleIdentifier: bundleIdentifier,
            shortVersion: shortVersion,
            buildVersion: buildVersion,
            path: appURL,
            sizeBytes: sizeBytes
        )
    }

    private func directorySize(at url: URL) -> Int64 {
        guard let enumerator = fileManager.enumerator(
            at: url,
            includingPropertiesForKeys: [.totalFileAllocatedSizeKey, .fileAllocatedSizeKey],
            options: [.skipsHiddenFiles]
        ) else {
            return 0
        }

        var size: Int64 = 0
        for case let fileURL as URL in enumerator {
            let values = try? fileURL.resourceValues(forKeys: [.totalFileAllocatedSizeKey, .fileAllocatedSizeKey])
            size += Int64(values?.totalFileAllocatedSize ?? values?.fileAllocatedSize ?? 0)
        }
        return size
    }
}
