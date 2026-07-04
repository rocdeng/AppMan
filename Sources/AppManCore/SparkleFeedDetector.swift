import Foundation

public protocol SparkleFeedDetecting: Sendable {
    func detectFeedURL(for app: AppRecord) throws -> URL?
}

public struct SparkleFeedDetector: SparkleFeedDetecting {
    public init() {}

    public func detectFeedURL(for app: AppRecord) throws -> URL? {
        let infoPlistURL = app.path
            .appendingPathComponent("Contents", isDirectory: true)
            .appendingPathComponent("Info.plist")

        guard FileManager.default.fileExists(atPath: infoPlistURL.path) else {
            return nil
        }

        let data = try Data(contentsOf: infoPlistURL)
        guard
            let plist = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
            let feedURLString = plist["SUFeedURL"] as? String
        else {
            return nil
        }

        return URL(string: feedURLString)
    }
}
