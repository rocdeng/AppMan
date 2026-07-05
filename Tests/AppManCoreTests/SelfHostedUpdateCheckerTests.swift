import XCTest
@testable import AppManCore

final class SelfHostedUpdateCheckerTests: XCTestCase {
    func testMarksManualAppAsPendingConfirmationWhenGoogleFindsCandidate() throws {
        let checker = SelfHostedUpdateChecker(
            sourceStore: SelfUpdateSourceStore(storeURL: temporaryURL()),
            googleSearcher: StubSelfUpdateSearcher(result: URL(string: "https://example.com/app")!),
            fetchData: { _ in Data() }
        )

        let apps = try checker.checkUpdates(for: [makeManualApp()])

        XCTAssertEqual(
            apps.first?.updateStatus,
            .needsOfficialWebsiteConfirmation(candidateURL: URL(string: "https://example.com/app")!)
        )
    }

    func testMarksManualAppAsNeedingManualInputWhenGoogleFindsNothing() throws {
        let checker = SelfHostedUpdateChecker(
            sourceStore: SelfUpdateSourceStore(storeURL: temporaryURL()),
            googleSearcher: StubSelfUpdateSearcher(result: nil),
            fetchData: { _ in Data() }
        )

        let apps = try checker.checkUpdates(for: [makeManualApp()])

        XCTAssertEqual(apps.first?.updateStatus, .needsManualUpdateURL)
    }

    func testUsesSavedUpdateURLToDetectLatestVersion() throws {
        let store = SelfUpdateSourceStore(storeURL: temporaryURL())
        try store.save(SelfUpdateSourceRecord(app: makeManualApp(), updateURL: URL(string: "https://example.com/download")!))
        let checker = SelfHostedUpdateChecker(
            sourceStore: store,
            googleSearcher: StubSelfUpdateSearcher(result: nil),
            fetchData: { _ in Data("Download version 2.4.0".utf8) }
        )

        let apps = try checker.checkUpdates(for: [makeManualApp(shortVersion: "2.3.0")])

        XCTAssertEqual(
            apps.first?.updateStatus,
            .updateAvailable(installedVersion: "2.3.0", latestVersion: "2.4.0")
        )
        XCTAssertEqual(apps.first?.updateURL, URL(string: "https://example.com/download"))
        XCTAssertEqual(apps.first?.updateURLIsDirectDownload, false)
    }

    func testUsesLatestPackageURLFromSavedUpdatePageWhenAvailable() throws {
        let store = SelfUpdateSourceStore(storeURL: temporaryURL())
        try store.save(SelfUpdateSourceRecord(app: makeManualApp(), updateURL: URL(string: "https://example.com/download")!))
        let checker = SelfHostedUpdateChecker(
            sourceStore: store,
            googleSearcher: StubSelfUpdateSearcher(result: nil),
            fetchData: { _ in Data("""
            <h1>Manual</h1>
            <p>Download version 2.4.0</p>
            <a href="/downloads/Manual-2.4.0.dmg">Download for macOS</a>
            """.utf8) }
        )

        let apps = try checker.checkUpdates(for: [makeManualApp(shortVersion: "2.3.0")])

        XCTAssertEqual(
            apps.first?.updateStatus,
            .updateAvailable(installedVersion: "2.3.0", latestVersion: "2.4.0")
        )
        XCTAssertEqual(apps.first?.updateURL, URL(string: "https://example.com/downloads/Manual-2.4.0.dmg"))
        XCTAssertEqual(apps.first?.updateURLIsDirectDownload, true)
    }

    func testUsesRecipeToDetectLatestVersionWithoutSearching() throws {
        let recipe = UpdateRecipe(
            id: "net.freemacsoft.AppCleaner",
            name: "AppCleaner",
            recipePrompt: "Use the official AppCleaner downloads section on freemacsoft.net.",
            match: UpdateRecipe.Match(
                bundleIdentifier: "net.freemacsoft.AppCleaner",
                appName: nil,
                officialHost: "freemacsoft.net"
            ),
            checks: [
                UpdateRecipe.Check(
                    url: URL(string: "https://freemacsoft.net/appcleaner/")!,
                    extract: UpdateRecipe.Extract(
                        type: .regex,
                        pattern: #"Version\s+([0-9]+(?:\.[0-9A-Za-z]+){1,5})"#,
                        versionGroup: 1
                    )
                ),
            ],
            updatePageURL: URL(string: "https://freemacsoft.net/appcleaner/")!,
            download: UpdateRecipe.Download(
                url: nil,
                sourceURL: URL(string: "https://freemacsoft.net/appcleaner/")!,
                pattern: #"href="([^"]*AppCleaner_3\.6\.8\.zip)""#,
                urlGroup: 1
            )
        )
        let checker = SelfHostedUpdateChecker(
            sourceStore: SelfUpdateSourceStore(storeURL: temporaryURL()),
            googleSearcher: FailingSelfUpdateSearcher(),
            recipeStore: StubUpdateRecipeStore(recipes: [recipe]),
            fetchData: { url in
                XCTAssertEqual(url, URL(string: "https://freemacsoft.net/appcleaner/")!)
                return Data("""
                <h3>Downloads</h3>
                <strong>Version 3.6.8</strong>
                <a href="/appcleaner/AppCleaner_3.6.8.zip">Download</a>
                <strong>Version 3.6</strong>
                """.utf8)
            }
        )

        let apps = try checker.checkUpdates(for: [makeAppCleaner(shortVersion: "3.6")])

        XCTAssertEqual(
            apps.first?.updateStatus,
            .updateAvailable(installedVersion: "3.6", latestVersion: "3.6.8")
        )
        XCTAssertEqual(apps.first?.updateURL, URL(string: "https://freemacsoft.net/appcleaner/AppCleaner_3.6.8.zip"))
        XCTAssertEqual(apps.first?.updateURLIsDirectDownload, true)
    }

    func testExplicitRecipeDownloadPrefersPackageMatchingLatestVersion() throws {
        let recipe = UpdateRecipe(
            id: "com.example.manual",
            name: "Manual",
            recipePrompt: "Prefer the package URL matching the latest detected version.",
            match: UpdateRecipe.Match(
                bundleIdentifier: "com.example.manual",
                appName: "Manual",
                officialHost: "example.com"
            ),
            checks: [
                UpdateRecipe.Check(
                    url: URL(string: "https://example.com/appcast.xml")!,
                    extract: UpdateRecipe.Extract(
                        type: .regex,
                        pattern: #"sparkle:version="([0-9]+(?:\.[0-9A-Za-z]+){1,5})""#,
                        versionGroup: 1
                    )
                ),
            ],
            updatePageURL: URL(string: "https://example.com/download")!,
            download: UpdateRecipe.Download(
                url: nil,
                sourceURL: URL(string: "https://example.com/appcast.xml")!,
                pattern: #"url="([^"]*Manual-[^"]+\.zip)""#,
                urlGroup: 1
            )
        )
        let checker = SelfHostedUpdateChecker(
            sourceStore: SelfUpdateSourceStore(storeURL: temporaryURL()),
            googleSearcher: FailingSelfUpdateSearcher(),
            recipeStore: StubUpdateRecipeStore(recipes: [recipe]),
            fetchData: { _ in Data("""
            <enclosure url="https://example.com/Manual-1_0_0.zip" sparkle:version="1.0.0" />
            <enclosure url="https://example.com/Manual-2_0_0.zip" sparkle:version="2.0.0" />
            """.utf8) }
        )

        let apps = try checker.checkUpdates(for: [makeManualApp(shortVersion: "1.0.0")])

        XCTAssertEqual(
            apps.first?.updateStatus,
            .updateAvailable(installedVersion: "1.0.0", latestVersion: "2.0.0")
        )
        XCTAssertEqual(apps.first?.updateURL, URL(string: "https://example.com/Manual-2_0_0.zip"))
        XCTAssertEqual(apps.first?.updateURLIsDirectDownload, true)
    }

    func testEmptyRecipeFallsBackToManualInputWithoutSearching() throws {
        let recipe = UpdateRecipe(
            id: "com.example.manual",
            name: "Manual",
            recipePrompt: "This app is known, but it has no stable public version endpoint.",
            match: UpdateRecipe.Match(
                bundleIdentifier: "com.example.manual",
                appName: "Manual",
                officialHost: nil
            ),
            checks: [],
            updatePageURL: URL(string: "https://example.com/download")!
        )
        let checker = SelfHostedUpdateChecker(
            sourceStore: SelfUpdateSourceStore(storeURL: temporaryURL()),
            googleSearcher: FailingSelfUpdateSearcher(),
            recipeStore: StubUpdateRecipeStore(recipes: [recipe]),
            fetchData: { _ in
                XCTFail("Empty recipes should not fetch version pages")
                return Data()
            }
        )

        let apps = try checker.checkUpdates(for: [makeManualApp()])

        XCTAssertEqual(apps.first?.updateStatus, .needsManualUpdateURL)
        XCTAssertEqual(apps.first?.updateURL, URL(string: "https://example.com/download"))
    }

    func testMarksSavedUpdateURLAsUndetectableWhenPageHasNoVersion() throws {
        let store = SelfUpdateSourceStore(storeURL: temporaryURL())
        try store.save(SelfUpdateSourceRecord(app: makeManualApp(), updateURL: URL(string: "https://example.com/download")!))
        let checker = SelfHostedUpdateChecker(
            sourceStore: store,
            googleSearcher: StubSelfUpdateSearcher(result: nil),
            fetchData: { _ in Data("Download the latest build".utf8) }
        )

        let apps = try checker.checkUpdates(for: [makeManualApp()])

        XCTAssertEqual(apps.first?.updateStatus, .undetectable)
    }

    func testTinyFishSearcherReturnsFirstAllowedCandidate() throws {
        let searcher = TinyFishSelfUpdateSearcher(apiKey: "sk-test") { url, headers in
            XCTAssertEqual(url.host, "api.search.tinyfish.ai")
            XCTAssertEqual(headers["X-API-Key"], "sk-test")
            XCTAssertTrue(url.absoluteString.contains("query=Manual"))
            return Data("""
            {
              "results": [
                {
                  "title": "Manual for Mac - Download",
                  "url": "https://manual.macupdate.com/"
                },
                {
                  "title": "Manual Official",
                  "url": "https://example.com/download?ref=search#top"
                }
              ]
            }
            """.utf8)
        }

        let url = try searcher.searchOfficialWebsite(for: makeManualApp())

        XCTAssertEqual(url, URL(string: "https://example.com/download"))
    }

    private func makeManualApp(shortVersion: String = "1.0") -> AppRecord {
        AppRecord(
            id: "com.example.manual",
            name: "Manual",
            bundleIdentifier: "com.example.manual",
            shortVersion: shortVersion,
            buildVersion: nil,
            path: URL(fileURLWithPath: "/Applications/Manual.app"),
            sizeBytes: 1,
            installSource: .manual(reason: "unknown")
        )
    }

    private func makeAppCleaner(shortVersion: String) -> AppRecord {
        AppRecord(
            id: "net.freemacsoft.AppCleaner",
            name: "AppCleaner",
            bundleIdentifier: "net.freemacsoft.AppCleaner",
            shortVersion: shortVersion,
            buildVersion: nil,
            path: URL(fileURLWithPath: "/Applications/AppCleaner.app"),
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

private struct StubSelfUpdateSearcher: SelfUpdateSearching {
    let result: URL?

    func searchOfficialWebsite(for app: AppRecord) throws -> URL? {
        result
    }
}

private struct FailingSelfUpdateSearcher: SelfUpdateSearching {
    func searchOfficialWebsite(for app: AppRecord) throws -> URL? {
        XCTFail("Recipe-backed checks should not search for a website first")
        return nil
    }
}

private struct StubUpdateRecipeStore: UpdateRecipeStoring {
    let recipes: [UpdateRecipe]

    func load() throws -> [UpdateRecipe] {
        recipes
    }
}
