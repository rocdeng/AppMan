import XCTest
@testable import AppManCore

final class SparkleAppcastUpdateCheckerTests: XCTestCase {
    func testMarksSparkleAppAsUpdateAvailableFromAppcastEnclosureVersion() throws {
        let feedURL = URL(string: "https://example.com/appcast.xml")!
        let checker = SparkleAppcastUpdateChecker(fetchData: { url in
            XCTAssertEqual(url, feedURL)
            return Data("""
            <?xml version="1.0" encoding="utf-8"?>
            <rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
              <channel>
                <item>
                  <title>Version 2.0</title>
                  <enclosure
                    url="https://example.com/Manual-2.0.zip"
                    sparkle:shortVersionString="2.0"
                    sparkle:version="200"
                  />
                </item>
              </channel>
            </rss>
            """.utf8)
        }, recipeStore: StubSparkleRecipeStore())
        let app = makeApp(feedURL: feedURL, shortVersion: "1.9")

        let apps = try checker.checkUpdates(for: [app])

        XCTAssertEqual(
            apps.first?.updateStatus,
            .updateAvailable(installedVersion: "1.9", latestVersion: "2.0")
        )
        XCTAssertEqual(apps.first?.updateURL, URL(string: "https://example.com/Manual-2.0.zip"))
        XCTAssertEqual(apps.first?.updateURLIsDirectDownload, true)
    }

    func testMarksSparkleAppAsUpToDateWhenAppcastVersionMatches() throws {
        let feedURL = URL(string: "https://example.com/appcast.xml")!
        let checker = SparkleAppcastUpdateChecker(fetchData: { _ in
            Data("""
            <rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
              <channel>
                <item>
                  <sparkle:shortVersionString>1.9</sparkle:shortVersionString>
                </item>
              </channel>
            </rss>
            """.utf8)
        }, recipeStore: StubSparkleRecipeStore())
        let app = makeApp(feedURL: feedURL, shortVersion: "1.9")

        let apps = try checker.checkUpdates(for: [app])

        XCTAssertEqual(apps.first?.updateStatus, .upToDate)
        XCTAssertEqual(apps.first?.updateURL, feedURL)
    }

    func testUsesHighestShortVersionWhenAppcastListsOlderItemsFirst() throws {
        let feedURL = URL(string: "https://example.com/appcast.xml")!
        let checker = SparkleAppcastUpdateChecker(fetchData: { _ in
            Data("""
            <rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
              <channel>
                <item>
                  <enclosure sparkle:shortVersionString="1.1.1" sparkle:version="100" />
                </item>
                <item>
                  <enclosure sparkle:shortVersionString="1.4.4" sparkle:version="144" />
                </item>
              </channel>
            </rss>
            """.utf8)
        }, recipeStore: StubSparkleRecipeStore())
        let app = makeApp(feedURL: feedURL, shortVersion: "1.4.3")

        let apps = try checker.checkUpdates(for: [app])

        XCTAssertEqual(
            apps.first?.updateStatus,
            .updateAvailable(installedVersion: "1.4.3", latestVersion: "1.4.4")
        )
    }

    func testUsesBundledRecipeWhenSparkleFeedRequiresQueryParameters() throws {
        let brokenFeedURL = URL(string: "https://example.com/update.php")!
        let recipeFeedURL = URL(string: "https://example.com/update.php?appName=Example&appVersion=5")!
        let packageURL = URL(string: "https://example.com/Example%205.2.0.zip")!
        let recipe = UpdateRecipe(
            id: "com.example.manual",
            name: "Manual",
            recipePrompt: nil,
            match: UpdateRecipe.Match(
                bundleIdentifier: "com.example.manual",
                appName: "Manual",
                officialHost: "example.com"
            ),
            checks: [
                UpdateRecipe.Check(
                    url: recipeFeedURL,
                    extract: UpdateRecipe.Extract(
                        type: .regex,
                        pattern: #"sparkle:shortVersionString="([0-9.]+)""#,
                        versionGroup: 1
                    )
                ),
            ],
            updatePageURL: URL(string: "https://example.com/manual")!,
            download: UpdateRecipe.Download(
                url: nil,
                sourceURL: recipeFeedURL,
                pattern: #"url="([^"]+\.zip)""#,
                urlGroup: 1
            )
        )
        let checker = SparkleAppcastUpdateChecker(
            fetchData: { url in
                XCTAssertEqual(url, recipeFeedURL)
                return Data("""
                <enclosure sparkle:shortVersionString="5.2.0" url="\(packageURL.absoluteString)" />
                """.utf8)
            },
            recipeStore: StubSparkleRecipeStore(recipes: [recipe])
        )

        let apps = try checker.checkUpdates(for: [makeApp(feedURL: brokenFeedURL, shortVersion: "5.1.0")])

        XCTAssertEqual(
            apps.first?.updateStatus,
            .updateAvailable(installedVersion: "5.1.0", latestVersion: "5.2.0")
        )
        XCTAssertEqual(apps.first?.updateURL, packageURL)
        XCTAssertEqual(apps.first?.updateURLIsDirectDownload, true)
    }

    func testRecipeCanCompareLatestVersionWithBundleBuildVersion() throws {
        let feedURL = URL(string: "https://files.example.com/snapshots/")!
        let packageURL = URL(string: "https://files.example.com/snapshots/App-2026.06.12.dmg")!
        let recipe = UpdateRecipe(
            id: "com.example.manual",
            name: "Manual",
            recipePrompt: nil,
            installedVersionSource: .buildVersion,
            match: UpdateRecipe.Match(
                bundleIdentifier: "com.example.manual",
                appName: "Manual",
                officialHost: "example.com"
            ),
            checks: [
                UpdateRecipe.Check(
                    url: feedURL,
                    extract: UpdateRecipe.Extract(
                        type: .linkRegex,
                        pattern: #"App-([0-9.]+)\.dmg"#,
                        versionGroup: 1
                    )
                ),
            ],
            updatePageURL: feedURL,
            download: UpdateRecipe.Download(
                url: packageURL,
                sourceURL: nil,
                pattern: nil,
                urlGroup: nil
            )
        )
        let checker = SparkleAppcastUpdateChecker(
            fetchData: { _ in Data("App-2026.06.12.dmg".utf8) },
            recipeStore: StubSparkleRecipeStore(recipes: [recipe])
        )

        let apps = try checker.checkUpdates(for: [
            makeApp(feedURL: feedURL, shortVersion: "2026.6", buildVersion: "2026.06.12"),
        ])

        XCTAssertEqual(apps.first?.updateStatus, .upToDate)
    }

    private func makeApp(
        feedURL: URL,
        shortVersion: String?,
        buildVersion: String? = nil
    ) -> AppRecord {
        AppRecord(
            id: "com.example.manual",
            name: "Manual",
            bundleIdentifier: "com.example.manual",
            shortVersion: shortVersion,
            buildVersion: buildVersion,
            path: URL(fileURLWithPath: "/Applications/Manual.app"),
            sizeBytes: 1,
            installSource: .sparkle(feedURL: feedURL)
        )
    }
}

private struct StubSparkleRecipeStore: UpdateRecipeStoring {
    let recipes: [UpdateRecipe]

    init(recipes: [UpdateRecipe] = []) {
        self.recipes = recipes
    }

    func load() throws -> [UpdateRecipe] { recipes }
}
