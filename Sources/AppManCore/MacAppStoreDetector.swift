import Foundation

public protocol MacAppStoreDetecting: Sendable {
    func isAppStoreApp(_ app: AppRecord) -> Bool
}

public struct MacAppStoreDetector: MacAppStoreDetecting {
    public init() {}

    public func isAppStoreApp(_ app: AppRecord) -> Bool {
        let receiptURL = app.path
            .appendingPathComponent("Contents", isDirectory: true)
            .appendingPathComponent("_MASReceipt", isDirectory: true)
            .appendingPathComponent("receipt")
        return FileManager.default.fileExists(atPath: receiptURL.path)
    }
}
