import XCTest
@testable import AppManCore

final class UpdateIgnoreListStoreTests: XCTestCase {
    func testLoadsEmptyListWhenFileDoesNotExist() throws {
        let store = UpdateIgnoreListStore(storeURL: temporaryURL())

        XCTAssertEqual(try store.load(), [])
    }

    func testSavesAndLoadsIgnoredApps() throws {
        let url = temporaryURL()
        let store = UpdateIgnoreListStore(storeURL: url)
        let app = AppRecord(
            id: "net.alkalay.RDM",
            name: "RDM",
            bundleIdentifier: "net.alkalay.RDM",
            shortVersion: "3.0",
            buildVersion: nil,
            path: URL(fileURLWithPath: "/Applications/RDM.app"),
            sizeBytes: 1,
            installSource: .homebrewCask(token: "usr-sse2-rdm")
        )

        try store.save([IgnoredAppRecord(app: app)])

        XCTAssertEqual(try store.load(), [IgnoredAppRecord(app: app)])
    }

    func testRemoveDeletesMatchingIDOnly() throws {
        let url = temporaryURL()
        let store = UpdateIgnoreListStore(storeURL: url)
        let rdm = IgnoredAppRecord(
            id: "net.alkalay.RDM",
            name: "RDM",
            bundleIdentifier: "net.alkalay.RDM",
            path: URL(fileURLWithPath: "/Applications/RDM.app"),
            sourceName: "BREW"
        )
        let iina = IgnoredAppRecord(
            id: "com.colliderli.iina",
            name: "IINA",
            bundleIdentifier: "com.colliderli.iina",
            path: URL(fileURLWithPath: "/Applications/IINA.app"),
            sourceName: "SELF"
        )
        try store.save([rdm, iina])

        let remaining = try store.remove(id: rdm.id)

        XCTAssertEqual(remaining, [iina])
        XCTAssertEqual(try store.load(), [iina])
    }

    func testRemoveDeletesMatchingPathOnlyWhenIDsAreDuplicated() throws {
        let url = temporaryURL()
        let store = UpdateIgnoreListStore(storeURL: url)
        let first = IgnoredAppRecord(
            id: "com.example.shared",
            name: "Shared First",
            bundleIdentifier: "com.example.shared",
            path: URL(fileURLWithPath: "/Applications/Shared First.app"),
            sourceName: "SELF"
        )
        let second = IgnoredAppRecord(
            id: "com.example.shared",
            name: "Shared Second",
            bundleIdentifier: "com.example.shared",
            path: URL(fileURLWithPath: "/Applications/Shared Second.app"),
            sourceName: "SELF"
        )
        try store.save([first, second])

        let remaining = try store.remove(path: first.path)

        XCTAssertEqual(remaining, [second])
        XCTAssertEqual(try store.load(), [second])
    }

    private func temporaryURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .appendingPathComponent("ignored-updates.json")
    }
}
