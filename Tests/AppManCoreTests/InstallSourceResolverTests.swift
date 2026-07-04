import XCTest
@testable import AppManCore

final class InstallSourceResolverTests: XCTestCase {
    func testHomebrewTakesPrecedenceOverMacAppStoreReceipt() throws {
        let resolver = InstallSourceResolver(
            homebrewDetector: StubHomebrewDetector(source: .homebrewCask(token: "visual-studio-code")),
            macAppStoreDetector: StubMacAppStoreDetector(isMacAppStoreApp: true)
        )
        let app = makeAppRecord(name: "Visual Studio Code")

        let source = try resolver.resolveInstallSource(for: app)

        XCTAssertEqual(source, .homebrewCask(token: "visual-studio-code"))
    }

    func testReturnsMacAppStoreWhenHomebrewIsNilAndReceiptExists() throws {
        let resolver = InstallSourceResolver(
            homebrewDetector: StubHomebrewDetector(source: nil),
            macAppStoreDetector: StubMacAppStoreDetector(isMacAppStoreApp: true)
        )
        let app = makeAppRecord(name: "Pages")

        let source = try resolver.resolveInstallSource(for: app)

        XCTAssertEqual(source, .macAppStore)
    }

    func testReturnsManualReasonWhenNoInstallEvidenceExists() throws {
        let resolver = InstallSourceResolver(
            homebrewDetector: StubHomebrewDetector(source: nil),
            macAppStoreDetector: StubMacAppStoreDetector(isMacAppStoreApp: false)
        )
        let app = makeAppRecord(name: "Manual")

        let source = try resolver.resolveInstallSource(for: app)

        XCTAssertEqual(
            source,
            .manual(reason: "没有找到 Homebrew Cask、Mac App Store 或 Sparkle 更新源证据")
        )
    }

    func testReturnsSparkleWhenAppHasFeedURL() throws {
        let feedURL = URL(string: "https://example.com/appcast.xml")!
        let resolver = InstallSourceResolver(
            homebrewDetector: StubHomebrewDetector(source: nil),
            macAppStoreDetector: StubMacAppStoreDetector(isMacAppStoreApp: false),
            sparkleFeedDetector: StubSparkleFeedDetector(feedURL: feedURL)
        )
        let app = makeAppRecord(name: "SparkleApp")

        let source = try resolver.resolveInstallSource(for: app)

        XCTAssertEqual(source, .sparkle(feedURL: feedURL))
    }

    func testResolveInstallSourcesUpdatesEachAppRecordInstallSource() throws {
        let resolver = InstallSourceResolver(
            homebrewDetector: NameBasedHomebrewDetector(sourcesByName: [
                "Code": .homebrewCask(token: "visual-studio-code"),
            ]),
            macAppStoreDetector: NameBasedMacAppStoreDetector(appStoreNames: ["Pages"])
        )
        let apps = [
            makeAppRecord(name: "Code"),
            makeAppRecord(name: "Pages"),
            makeAppRecord(name: "Manual"),
        ]

        let resolvedApps = try resolver.resolveInstallSources(for: apps)

        XCTAssertEqual(resolvedApps.map(\.installSource), [
            .homebrewCask(token: "visual-studio-code"),
            .macAppStore,
            .manual(reason: "没有找到 Homebrew Cask、Mac App Store 或 Sparkle 更新源证据"),
        ])
    }

    func testMacAppStoreDetectorFindsReceiptInAppBundle() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let receiptURL = root
            .appendingPathComponent("ReceiptApp.app", isDirectory: true)
            .appendingPathComponent("Contents", isDirectory: true)
            .appendingPathComponent("_MASReceipt", isDirectory: true)
            .appendingPathComponent("receipt")
        try FileManager.default.createDirectory(
            at: receiptURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        FileManager.default.createFile(atPath: receiptURL.path, contents: Data())
        let app = makeAppRecord(
            name: "ReceiptApp",
            path: root.appendingPathComponent("ReceiptApp.app", isDirectory: true)
        )

        XCTAssertTrue(MacAppStoreDetector().isAppStoreApp(app))
    }

    func testSparkleFeedDetectorFindsSUFeedURLInAppBundle() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let appURL = root.appendingPathComponent("SparkleApp.app", isDirectory: true)
        let contentsURL = appURL.appendingPathComponent("Contents", isDirectory: true)
        try FileManager.default.createDirectory(at: contentsURL, withIntermediateDirectories: true)

        let feedURL = URL(string: "https://example.com/appcast.xml")!
        let plist: [String: Any] = [
            "CFBundleIdentifier": "com.example.sparkle",
            "CFBundleName": "SparkleApp",
            "SUFeedURL": feedURL.absoluteString,
        ]
        let plistData = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try plistData.write(to: contentsURL.appendingPathComponent("Info.plist"))
        let app = makeAppRecord(name: "SparkleApp", path: appURL)

        let detectedFeedURL = try SparkleFeedDetector().detectFeedURL(for: app)

        XCTAssertEqual(detectedFeedURL, feedURL)
    }

    private func makeAppRecord(
        name: String,
        path: URL = URL(fileURLWithPath: "/Applications/Test.app")
    ) -> AppRecord {
        AppRecord(
            id: "com.example.\(name)",
            name: name,
            bundleIdentifier: "com.example.\(name)",
            shortVersion: nil,
            buildVersion: nil,
            path: path,
            sizeBytes: 0
        )
    }
}

private struct StubHomebrewDetector: HomebrewDetecting {
    let source: InstallSource?

    func detectInstallSource(for app: AppRecord) throws -> InstallSource? {
        source
    }
}

private struct StubMacAppStoreDetector: MacAppStoreDetecting {
    let isMacAppStoreApp: Bool

    func isAppStoreApp(_ app: AppRecord) -> Bool {
        isMacAppStoreApp
    }
}

private struct NameBasedHomebrewDetector: HomebrewDetecting {
    let sourcesByName: [String: InstallSource]

    func detectInstallSource(for app: AppRecord) throws -> InstallSource? {
        sourcesByName[app.name]
    }
}

private struct NameBasedMacAppStoreDetector: MacAppStoreDetecting {
    let appStoreNames: Set<String>

    func isAppStoreApp(_ app: AppRecord) -> Bool {
        appStoreNames.contains(app.name)
    }
}

private struct StubSparkleFeedDetector: SparkleFeedDetecting {
    let feedURL: URL?

    func detectFeedURL(for app: AppRecord) throws -> URL? {
        feedURL
    }
}
