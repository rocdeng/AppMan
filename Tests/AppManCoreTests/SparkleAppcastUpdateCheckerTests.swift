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
                  <enclosure sparkle:shortVersionString="2.0" sparkle:version="200" />
                </item>
              </channel>
            </rss>
            """.utf8)
        })
        let app = makeApp(feedURL: feedURL, shortVersion: "1.9")

        let apps = try checker.checkUpdates(for: [app])

        XCTAssertEqual(
            apps.first?.updateStatus,
            .updateAvailable(installedVersion: "1.9", latestVersion: "2.0")
        )
        XCTAssertEqual(apps.first?.updateURL, feedURL)
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
        })
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
        })
        let app = makeApp(feedURL: feedURL, shortVersion: "1.4.3")

        let apps = try checker.checkUpdates(for: [app])

        XCTAssertEqual(
            apps.first?.updateStatus,
            .updateAvailable(installedVersion: "1.4.3", latestVersion: "1.4.4")
        )
    }

    private func makeApp(feedURL: URL, shortVersion: String?) -> AppRecord {
        AppRecord(
            id: "com.example.manual",
            name: "Manual",
            bundleIdentifier: "com.example.manual",
            shortVersion: shortVersion,
            buildVersion: nil,
            path: URL(fileURLWithPath: "/Applications/Manual.app"),
            sizeBytes: 1,
            installSource: .sparkle(feedURL: feedURL)
        )
    }
}
