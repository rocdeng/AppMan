import XCTest
@testable import AppManCore

final class AppRecordCacheTests: XCTestCase {
    func testLoadsEmptyArrayWhenCacheDoesNotExist() throws {
        let cache = AppRecordCache(cacheURL: temporaryCacheURL())

        let apps = try cache.load()

        XCTAssertEqual(apps, [])
    }

    func testSavesAndLoadsAppRecords() throws {
        let cacheURL = temporaryCacheURL()
        let cache = AppRecordCache(cacheURL: cacheURL)
        let apps = [
            AppRecord(
                id: "com.example.test",
                name: "Test",
                bundleIdentifier: "com.example.test",
                shortVersion: "1.0",
                buildVersion: "100",
                path: URL(fileURLWithPath: "/Applications/Test.app"),
                sizeBytes: 123,
                installSource: .homebrewCask(token: "test"),
                updateStatus: .updateAvailable(installedVersion: "1.0", latestVersion: "1.1")
            )
        ]

        try cache.save(apps)
        let loadedApps = try cache.load()

        XCTAssertEqual(loadedApps, apps)
    }

    private func temporaryCacheURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .appendingPathComponent("apps-cache.json")
    }
}
