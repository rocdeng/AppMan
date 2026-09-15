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

    func testDoesNotMatchShortDirectoryContainedInAppName() throws {
        let root = try makeTemporaryDirectory()
        let appURL = root.appendingPathComponent("Applications/Google Chrome.app", isDirectory: true)
        let directories = ["Application Support", "Caches", "Logs"]
        try FileManager.default.createDirectory(at: appURL, withIntermediateDirectories: true)
        for directory in directories {
            try FileManager.default.createDirectory(
                at: root.appendingPathComponent("Library/\(directory)/Google", isDirectory: true),
                withIntermediateDirectories: true
            )
            for unrelatedName in ["go", "com"] {
                try FileManager.default.createDirectory(
                    at: root.appendingPathComponent("Library/\(directory)/\(unrelatedName)", isDirectory: true),
                    withIntermediateDirectories: true
                )
            }
        }

        let app = AppRecord(
            id: "google-chrome",
            name: "Google Chrome",
            bundleIdentifier: "com.google.Chrome",
            shortVersion: nil,
            buildVersion: nil,
            path: appURL,
            sizeBytes: 0
        )
        let finder = UninstallCandidateFinder(
            libraryDirectory: root.appendingPathComponent("Library", isDirectory: true),
            downloadsDirectory: nil
        )

        let candidates = try finder.findCandidates(for: app)

        XCTAssertEqual(candidates.filter { $0.name == "Google" }.count, 3)
        XCTAssertFalse(candidates.contains { $0.name == "go" })
        XCTAssertFalse(candidates.contains { $0.name == "com" })
    }

    func testFindsSandboxScriptsAndGroupContainer() throws {
        let root = try makeTemporaryDirectory()
        let appURL = root.appendingPathComponent("Applications/Clash Mi.app", isDirectory: true)
        let applicationScriptURL = root.appendingPathComponent("Library/Application Scripts/com.nebula.clashmi", isDirectory: true)
        let containerURL = root.appendingPathComponent("Library/Containers/com.nebula.clashmi", isDirectory: true)
        let groupContainerURL = root.appendingPathComponent("Library/Group Containers/group.com.nebula.clashmi", isDirectory: true)
        let unrelatedGroupURL = root.appendingPathComponent("Library/Group Containers/group.com.example.other", isDirectory: true)
        for url in [appURL, applicationScriptURL, containerURL, groupContainerURL, unrelatedGroupURL] {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        }

        let app = AppRecord(
            id: "clash-mi",
            name: "Clash Mi",
            bundleIdentifier: "com.nebula.clashmi",
            shortVersion: nil,
            buildVersion: nil,
            path: appURL,
            sizeBytes: 0
        )
        let finder = UninstallCandidateFinder(
            libraryDirectory: root.appendingPathComponent("Library", isDirectory: true),
            downloadsDirectory: root.appendingPathComponent("Downloads", isDirectory: true)
        )

        let candidates = try finder.findCandidates(for: app)

        XCTAssertEqual(
            candidates.map { $0.url.standardizedFileURL.path },
            [appURL, applicationScriptURL, containerURL, groupContainerURL].map { $0.standardizedFileURL.path }
        )
        XCTAssertEqual(candidates.map(\.kind), [.application, .applicationScript, .container, .groupContainer])
    }

    func testFindsNestedBundleDataAndDoesNotMatchNamePrefix() throws {
        let root = try makeTemporaryDirectory()
        let appURL = root.appendingPathComponent("Applications/Doubao.app", isDirectory: true)
        let extensionURL = appURL.appendingPathComponent("Contents/PlugIns/finder-ext.appex", isDirectory: true)
        let supportURL = root.appendingPathComponent("Library/Application Support/Doubao", isDirectory: true)
        let falsePositiveURL = root.appendingPathComponent("Library/Application Support/DoubaoIme", isDirectory: true)
        let httpStorageURL = root.appendingPathComponent("Library/HTTPStorages/com.example.doubao.extension", isDirectory: true)
        let extensionScriptsURL = root.appendingPathComponent("Library/Application Scripts/com.example.doubao.extension", isDirectory: true)
        let extensionContainerURL = root.appendingPathComponent("Library/Containers/com.example.doubao.extension", isDirectory: true)
        let extensionPreferenceURL = root.appendingPathComponent("Library/Preferences/com.example.doubao.extension.helper.plist")
        try FileManager.default.createDirectory(at: appURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: extensionURL.appendingPathComponent("Contents", isDirectory: true),
            withIntermediateDirectories: true
        )
        for url in [supportURL, falsePositiveURL, httpStorageURL, extensionScriptsURL, extensionContainerURL] {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        }
        try FileManager.default.createDirectory(at: extensionPreferenceURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("preference".utf8).write(to: extensionPreferenceURL)
        let plist: [String: String] = ["CFBundleIdentifier": "com.example.doubao.extension"]
        let plistData = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try plistData.write(to: extensionURL.appendingPathComponent("Contents/Info.plist"))

        let app = AppRecord(
            id: "doubao",
            name: "Doubao",
            bundleIdentifier: "com.example.doubao",
            shortVersion: nil,
            buildVersion: nil,
            path: appURL,
            sizeBytes: 0
        )
        let finder = UninstallCandidateFinder(
            libraryDirectory: root.appendingPathComponent("Library", isDirectory: true),
            downloadsDirectory: nil
        )

        let candidates = try finder.findCandidates(for: app)

        let candidatePaths = Set(candidates.map { $0.url.standardizedFileURL.path })
        XCTAssertTrue(candidatePaths.contains(supportURL.standardizedFileURL.path))
        XCTAssertTrue(candidatePaths.contains(httpStorageURL.standardizedFileURL.path))
        XCTAssertTrue(candidatePaths.contains(extensionScriptsURL.standardizedFileURL.path))
        XCTAssertTrue(candidatePaths.contains(extensionContainerURL.standardizedFileURL.path))
        XCTAssertTrue(candidatePaths.contains(extensionPreferenceURL.standardizedFileURL.path))
        XCTAssertFalse(candidatePaths.contains(falsePositiveURL.standardizedFileURL.path))
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
