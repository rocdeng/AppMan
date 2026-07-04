import XCTest
@testable import AppManCore

final class AppPreferencesStoreTests: XCTestCase {
    func testLoadsDefaultPreferencesWhenFileDoesNotExist() throws {
        let store = AppPreferencesStore(storeURL: temporaryURL())

        XCTAssertEqual(try store.load(), AppPreferences())
    }

    func testSavesAndLoadsAutoCheckPreference() throws {
        let url = temporaryURL()
        let store = AppPreferencesStore(storeURL: url)

        try store.save(AppPreferences(
            automaticallyChecksUpdatesOnLaunch: true,
            tinyFishAPIKey: "sk-test"
        ))

        XCTAssertEqual(
            try store.load(),
            AppPreferences(automaticallyChecksUpdatesOnLaunch: true, tinyFishAPIKey: "sk-test")
        )
    }

    private func temporaryURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .appendingPathComponent("preferences.json")
    }
}
