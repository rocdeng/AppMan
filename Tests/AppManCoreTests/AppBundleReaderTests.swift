import XCTest
@testable import AppManCore

final class AppBundleReaderTests: XCTestCase {
    func testReadsInfoPlistMetadata() throws {
        let appURL = try fixtureURL("TestApp.app")
        let reader = AppBundleReader()

        let record = try reader.readApp(at: appURL)

        XCTAssertEqual(record.name, "测试应用")
        XCTAssertEqual(record.bundleIdentifier, "com.example.testapp")
        XCTAssertEqual(record.shortVersion, "1.2.3")
        XCTAssertEqual(record.buildVersion, "123")
        XCTAssertEqual(record.path, appURL)
        XCTAssertGreaterThan(record.sizeBytes, 0)
        XCTAssertEqual(record.installSource, .manual(reason: "尚未识别到安装渠道"))
    }

    func testFallsBackToFileNameWhenDisplayNameIsMissing() throws {
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let appURL = temporaryDirectory.appendingPathComponent("FallbackName.app", isDirectory: true)
        let contentsURL = appURL.appendingPathComponent("Contents", isDirectory: true)
        try FileManager.default.createDirectory(at: contentsURL, withIntermediateDirectories: true)
        let plistURL = contentsURL.appendingPathComponent("Info.plist")
        let plist = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>CFBundleIdentifier</key>
            <string>com.example.fallback</string>
        </dict>
        </plist>
        """
        try plist.write(to: plistURL, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

        let record = try AppBundleReader().readApp(at: appURL)

        XCTAssertEqual(record.name, "FallbackName")
        XCTAssertEqual(record.bundleIdentifier, "com.example.fallback")
    }

    func testRefreshMetadataKeepsCachedFieldsAndUpdatesVersion() throws {
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let appURL = temporaryDirectory.appendingPathComponent("Refreshing.app", isDirectory: true)
        try writeInfoPlist(
            to: appURL,
            bundleIdentifier: "com.example.refreshing",
            shortVersion: "1.0",
            buildVersion: "100"
        )
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

        let original = AppRecord(
            id: "com.example.refreshing",
            name: "Refreshing",
            bundleIdentifier: "com.example.refreshing",
            shortVersion: "0.9",
            buildVersion: "90",
            path: appURL,
            sizeBytes: 12345,
            installSource: .macAppStore,
            updateStatus: .updateAvailable(installedVersion: "0.9", latestVersion: "1.0"),
            updateURL: URL(string: "macappstore://itunes.apple.com/app/id123"),
            updateURLIsDirectDownload: true
        )

        let refreshed = try AppBundleReader().refreshMetadata(for: original)

        XCTAssertEqual(refreshed.shortVersion, "1.0")
        XCTAssertEqual(refreshed.buildVersion, "100")
        XCTAssertEqual(refreshed.sizeBytes, original.sizeBytes)
        XCTAssertEqual(refreshed.installSource, original.installSource)
        XCTAssertEqual(refreshed.updateStatus, original.updateStatus)
        XCTAssertEqual(refreshed.updateURL, original.updateURL)
        XCTAssertEqual(refreshed.updateURLIsDirectDownload, original.updateURLIsDirectDownload)
    }

    private func fixtureURL(_ name: String) throws -> URL {
        let bundle = Bundle.module
        let fixturesURL = bundle.resourceURL!.appendingPathComponent("Fixtures", isDirectory: true)
        let url = fixturesURL.appendingPathComponent(name, isDirectory: true)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        return url
    }

    private func writeInfoPlist(
        to appURL: URL,
        bundleIdentifier: String,
        shortVersion: String,
        buildVersion: String
    ) throws {
        let contentsURL = appURL.appendingPathComponent("Contents", isDirectory: true)
        try FileManager.default.createDirectory(at: contentsURL, withIntermediateDirectories: true)
        let plistURL = contentsURL.appendingPathComponent("Info.plist")
        let plist = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>CFBundleName</key>
            <string>Refreshing</string>
            <key>CFBundleIdentifier</key>
            <string>\(bundleIdentifier)</string>
            <key>CFBundleShortVersionString</key>
            <string>\(shortVersion)</string>
            <key>CFBundleVersion</key>
            <string>\(buildVersion)</string>
        </dict>
        </plist>
        """
        try plist.write(to: plistURL, atomically: true, encoding: .utf8)
    }
}
