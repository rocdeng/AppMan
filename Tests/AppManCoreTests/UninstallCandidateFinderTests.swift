import XCTest
@testable import AppManCore

final class UninstallCandidateFinderTests: XCTestCase {
    func testFindsAppAndExistingSupportFiles() throws {
        let root = try makeTemporaryDirectory()
        let appURL = root.appendingPathComponent("Applications/Sample.app", isDirectory: true)
        let supportURL = root.appendingPathComponent("Library/Application Support/com.example.sample", isDirectory: true)
        let cacheURL = root.appendingPathComponent("Library/Caches/Sample", isDirectory: true)
        let prefsURL = root.appendingPathComponent("Library/Preferences/com.example.sample.plist")
        let downloadURL = root.appendingPathComponent("Downloads/Sample Installer.dmg")
        try FileManager.default.createDirectory(at: appURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: supportURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: cacheURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: prefsURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: downloadURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: 1, count: 7).write(to: appURL.appendingPathComponent("Contents.bin"))
        try Data(repeating: 2, count: 11).write(to: supportURL.appendingPathComponent("Data.bin"))
        try Data(repeating: 3, count: 13).write(to: cacheURL.appendingPathComponent("Cache.bin"))
        try Data(repeating: 4, count: 17).write(to: prefsURL)
        try Data(repeating: 5, count: 19).write(to: downloadURL)

        let app = AppRecord(
            id: "sample",
            name: "Sample",
            bundleIdentifier: "com.example.sample",
            shortVersion: nil,
            buildVersion: nil,
            path: appURL,
            sizeBytes: 7
        )
        let finder = UninstallCandidateFinder(
            libraryDirectory: root.appendingPathComponent("Library", isDirectory: true),
            downloadsDirectory: root.appendingPathComponent("Downloads", isDirectory: true)
        )

        let candidates = try finder.findCandidates(for: app)

        XCTAssertEqual(
            candidates.map { $0.url.standardizedFileURL.path },
            [appURL, supportURL, cacheURL, prefsURL, downloadURL].map { $0.standardizedFileURL.path }
        )
        XCTAssertEqual(candidates.map(\.kind), [.application, .applicationSupport, .cache, .preferences, .installer])
        XCTAssertEqual(candidates.map(\.sizeBytes), [7, 11, 13, 17, 19])
    }

    func testSkipsMissingAndUnrelatedPaths() throws {
        let root = try makeTemporaryDirectory()
        let appURL = root.appendingPathComponent("Applications/Sample.app", isDirectory: true)
        let unrelatedURL = root.appendingPathComponent("Downloads/Other.dmg")
        try FileManager.default.createDirectory(at: appURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: unrelatedURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: 1, count: 3).write(to: appURL.appendingPathComponent("Contents.bin"))
        try Data(repeating: 2, count: 5).write(to: unrelatedURL)

        let app = AppRecord(
            id: "sample",
            name: "Sample",
            bundleIdentifier: "com.example.sample",
            shortVersion: nil,
            buildVersion: nil,
            path: appURL,
            sizeBytes: 3
        )
        let finder = UninstallCandidateFinder(
            libraryDirectory: root.appendingPathComponent("Library", isDirectory: true),
            downloadsDirectory: root.appendingPathComponent("Downloads", isDirectory: true)
        )

        let candidates = try finder.findCandidates(for: app)

        XCTAssertEqual(candidates.map { $0.url.standardizedFileURL.path }, [appURL.standardizedFileURL.path])
    }

    func testFindsVendorDirectoryFromBundleIdentifier() throws {
        let root = try makeTemporaryDirectory()
        let appURL = root.appendingPathComponent("Applications/Android Studio.app", isDirectory: true)
        let vendorSupportURL = root.appendingPathComponent("Library/Application Support/Google", isDirectory: true)
        try FileManager.default.createDirectory(at: appURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: vendorSupportURL, withIntermediateDirectories: true)
        try Data(repeating: 1, count: 3).write(to: appURL.appendingPathComponent("Contents.bin"))
        try Data(repeating: 2, count: 5).write(to: vendorSupportURL.appendingPathComponent("Data.bin"))

        let app = AppRecord(
            id: "android-studio",
            name: "Android Studio",
            bundleIdentifier: "com.google.android.studio",
            shortVersion: nil,
            buildVersion: nil,
            path: appURL,
            sizeBytes: 3
        )
        let finder = UninstallCandidateFinder(
            libraryDirectory: root.appendingPathComponent("Library", isDirectory: true),
            downloadsDirectory: root.appendingPathComponent("Downloads", isDirectory: true)
        )

        let candidates = try finder.findCandidates(for: app)

        XCTAssertTrue(candidates.contains { $0.url.standardizedFileURL.path == vendorSupportURL.standardizedFileURL.path })
    }

    private func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: url)
        }
        return url
    }
}
