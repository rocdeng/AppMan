import XCTest
@testable import AppManCore

final class MacAppStoreUpdateCheckerTests: XCTestCase {
    func testMarksMacAppStoreAppAsUpdateAvailableFromLookupVersion() throws {
        let checker = MacAppStoreUpdateChecker(fetchData: { url in
            XCTAssertEqual(url.host, "itunes.apple.com")
            XCTAssertTrue(url.absoluteString.contains("bundleId=com.example.pages"))
            return Data("""
            {
              "resultCount": 1,
              "results": [
                {
                  "bundleId": "com.example.pages",
                  "version": "14.2",
                  "trackId": 409201541,
                  "trackViewUrl": "https://apps.apple.com/app/pages/id409201541"
                }
              ]
            }
            """.utf8)
        })
        let app = makeApp(shortVersion: "14.1")

        let apps = try checker.checkUpdates(for: [app])

        XCTAssertEqual(
            apps.first?.updateStatus,
            .updateAvailable(installedVersion: "14.1", latestVersion: "14.2")
        )
        XCTAssertEqual(apps.first?.updateURL, URL(string: "macappstore://itunes.apple.com/app/id409201541"))
    }

    func testMarksMacAppStoreAppAsUpToDateWhenLookupVersionMatches() throws {
        let checker = MacAppStoreUpdateChecker(fetchData: { _ in
            Data("""
            {
              "resultCount": 1,
              "results": [
                {
                  "bundleId": "com.example.pages",
                  "version": "14.1",
                  "trackId": 409201541,
                  "trackViewUrl": "https://apps.apple.com/app/pages/id409201541"
                }
              ]
            }
            """.utf8)
        })
        let app = makeApp(shortVersion: "14.1")

        let apps = try checker.checkUpdates(for: [app])

        XCTAssertEqual(apps.first?.updateStatus, .upToDate)
        XCTAssertEqual(apps.first?.updateURL, URL(string: "macappstore://itunes.apple.com/app/id409201541"))
    }

    func testMarksMacAppStoreAppAsUnsupportedWithoutBundleIdentifier() throws {
        let checker = MacAppStoreUpdateChecker(fetchData: { _ in
            XCTFail("Lookup should not run without a bundle identifier")
            return Data()
        })
        var app = makeApp(shortVersion: "14.1")
        app = AppRecord(
            id: app.id,
            name: app.name,
            bundleIdentifier: nil,
            shortVersion: app.shortVersion,
            buildVersion: app.buildVersion,
            path: app.path,
            sizeBytes: app.sizeBytes,
            installSource: app.installSource
        )

        let apps = try checker.checkUpdates(for: [app])

        XCTAssertEqual(apps.first?.updateStatus, .unsupported(reason: "缺少 Bundle ID，无法查询 App Store"))
    }

    func testFallsBackToAdamIDWithoutCountryWhenBundleLookupFindsNoResult() throws {
        let requestedURLs = RequestedURLRecorder()
        let checker = MacAppStoreUpdateChecker(
            countryCode: "cn",
            appStoreIDProvider: { _ in "1451685025" },
            fetchData: { url in
                requestedURLs.append(url.absoluteString)
                if url.absoluteString.contains("id=1451685025"), !url.absoluteString.contains("country=") {
                    return Data("""
                    {
                      "resultCount": 1,
                      "results": [
                        {
                          "bundleId": "com.wireguard.macos",
                          "version": "1.0.16"
                        }
                      ]
                    }
                    """.utf8)
                }

                return Data("""
                {
                  "resultCount": 0,
                  "results": []
                }
                """.utf8)
            }
        )
        let app = AppRecord(
            id: "com.wireguard.macos",
            name: "WireGuard",
            bundleIdentifier: "com.wireguard.macos",
            shortVersion: "1.0.16",
            buildVersion: nil,
            path: URL(fileURLWithPath: "/Applications/WireGuard.app"),
            sizeBytes: 1,
            installSource: .macAppStore
        )

        let apps = try checker.checkUpdates(for: [app])

        XCTAssertEqual(apps.first?.updateStatus, .upToDate)
        let urls = requestedURLs.values
        XCTAssertEqual(urls.count, 4)
        XCTAssertTrue(urls[0].contains("bundleId=com.wireguard.macos"))
        XCTAssertTrue(urls[0].contains("country=cn"))
        XCTAssertTrue(urls[1].contains("bundleId=com.wireguard.macos"))
        XCTAssertFalse(urls[1].contains("country="))
        XCTAssertTrue(urls[2].contains("id=1451685025"))
        XCTAssertTrue(urls[2].contains("country=cn"))
        XCTAssertTrue(urls[3].contains("id=1451685025"))
        XCTAssertFalse(urls[3].contains("country="))
    }

    private func makeApp(shortVersion: String?) -> AppRecord {
        AppRecord(
            id: "com.example.pages",
            name: "Pages",
            bundleIdentifier: "com.example.pages",
            shortVersion: shortVersion,
            buildVersion: nil,
            path: URL(fileURLWithPath: "/Applications/Pages.app"),
            sizeBytes: 1,
            installSource: .macAppStore
        )
    }
}

private final class RequestedURLRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String] = []

    var values: [String] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func append(_ url: String) {
        lock.lock()
        storage.append(url)
        lock.unlock()
    }
}
