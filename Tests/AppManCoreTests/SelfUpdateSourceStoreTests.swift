import XCTest
@testable import AppManCore

final class SelfUpdateSourceStoreTests: XCTestCase {
    func testSavesAndLoadsSelfUpdateSource() throws {
        let store = SelfUpdateSourceStore(storeURL: temporaryURL())
        let app = makeApp()
        let record = SelfUpdateSourceRecord(app: app, updateURL: URL(string: "https://example.com/download")!)

        try store.save(record)

        XCTAssertEqual(try store.record(for: app)?.updateURL, URL(string: "https://example.com/download")!)
        XCTAssertEqual(try store.load(), [record])
    }

    func testReplacesRecordWithSameBundleIdentifier() throws {
        let store = SelfUpdateSourceStore(storeURL: temporaryURL())
        let firstApp = makeApp(id: "path-1")
        let secondApp = makeApp(id: "path-2")

        try store.save(SelfUpdateSourceRecord(app: firstApp, updateURL: URL(string: "https://old.example.com")!))
        try store.save(SelfUpdateSourceRecord(app: secondApp, updateURL: URL(string: "https://new.example.com")!))

        XCTAssertEqual(try store.load().map(\.updateURL), [URL(string: "https://new.example.com")!])
    }

    private func makeApp(id: String = "com.example.manual") -> AppRecord {
        AppRecord(
            id: id,
            name: "Manual",
            bundleIdentifier: "com.example.manual",
            shortVersion: "1.0",
            buildVersion: nil,
            path: URL(fileURLWithPath: "/Applications/Manual.app"),
            sizeBytes: 1,
            installSource: .manual(reason: "unknown")
        )
    }

    private func temporaryURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("json")
    }
}
