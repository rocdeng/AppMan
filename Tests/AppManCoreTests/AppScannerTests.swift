import XCTest
@testable import AppManCore

final class AppScannerTests: XCTestCase {
    func testScansOnlyAppBundlesInConfiguredRoots() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let appsDirectory = root.appendingPathComponent("Applications", isDirectory: true)
        try FileManager.default.createDirectory(at: appsDirectory, withIntermediateDirectories: true)
        try createApp(named: "Alpha.app", bundleID: "com.example.alpha", in: appsDirectory)
        try createApp(named: "Beta.app", bundleID: "com.example.beta", in: appsDirectory)
        try "not an app".write(
            to: appsDirectory.appendingPathComponent("notes.txt"),
            atomically: true,
            encoding: .utf8
        )

        let scanner = AppScanner(scanRoots: [appsDirectory])
        let records = try scanner.scanInstalledApps()

        XCTAssertEqual(records.map(\.name).sorted(), ["Alpha", "Beta"])
        XCTAssertEqual(records.map(\.bundleIdentifier).compactMap { $0 }.sorted(), [
            "com.example.alpha",
            "com.example.beta",
        ])
    }

    func testMissingScanRootIsIgnored() throws {
        let missingRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let scanner = AppScanner(scanRoots: [missingRoot])

        let records = try scanner.scanInstalledApps()

        XCTAssertEqual(records, [])
    }

    private func createApp(named name: String, bundleID: String, in directory: URL) throws {
        let appURL = directory.appendingPathComponent(name, isDirectory: true)
        let contentsURL = appURL.appendingPathComponent("Contents", isDirectory: true)
        try FileManager.default.createDirectory(at: contentsURL, withIntermediateDirectories: true)
        let appName = appURL.deletingPathExtension().lastPathComponent
        let plist = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>CFBundleName</key>
            <string>\(appName)</string>
            <key>CFBundleIdentifier</key>
            <string>\(bundleID)</string>
        </dict>
        </plist>
        """
        try plist.write(
            to: contentsURL.appendingPathComponent("Info.plist"),
            atomically: true,
            encoding: .utf8
        )
    }
}
