import XCTest
@testable import AppManCore

final class DownloadedAppInstallerTests: XCTestCase {
    func testDoesNotTreatBundledBackgroundToolAsRunningMainApp() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let appURL = root.appendingPathComponent("Pencil.app", isDirectory: true)
        try makeApp(
            at: appURL,
            bundleIdentifier: "dev.pencil.desktop",
            version: "1.0",
            executableName: "Pencil"
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let app = AppRecord(
            id: "dev.pencil.desktop",
            name: "Pencil",
            bundleIdentifier: "dev.pencil.desktop",
            shortVersion: "1.0",
            buildVersion: "1",
            path: appURL,
            sizeBytes: 1,
            installSource: .manual(reason: "self")
        )

        XCTAssertTrue(InstalledApplicationLifecycleManager.isMainApplication(
            bundleIdentifier: "dev.pencil.desktop",
            executableURL: appURL.appendingPathComponent("Contents/MacOS/Pencil"),
            app: app
        ))
        XCTAssertFalse(InstalledApplicationLifecycleManager.isMainApplication(
            bundleIdentifier: nil,
            executableURL: appURL.appendingPathComponent(
                "Contents/Resources/app.asar.unpacked/out/mcp-server-darwin-arm64"
            ),
            app: app
        ))
    }

    func testInstallsAppFromZipAndMovesOldVersionToTrash() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let sourceRoot = root.appendingPathComponent("Source", isDirectory: true)
        let destinationURL = root.appendingPathComponent("Applications/Test.app", isDirectory: true)
        let archiveURL = root.appendingPathComponent("Test.zip")
        try makeApp(at: sourceRoot.appendingPathComponent("Test.app"), bundleIdentifier: "com.example.test", version: "2.0")
        try makeApp(at: destinationURL, bundleIdentifier: "com.example.test", version: "1.0")
        try Data().write(to: archiveURL)
        defer { try? FileManager.default.removeItem(at: root) }

        let trashURL = root.appendingPathComponent("Trash", isDirectory: true)
        try FileManager.default.createDirectory(at: trashURL, withIntermediateDirectories: true)
        let runner = StubDownloadedAppCommandRunner { executable, arguments in
            XCTAssertEqual(executable, "ditto")
            try FileManager.default.copyItem(
                at: sourceRoot.appendingPathComponent("Test.app"),
                to: URL(fileURLWithPath: arguments.last!).appendingPathComponent("Test.app")
            )
            return ""
        }
        let installer = DownloadedAppInstaller(
            commandRunner: runner,
            moveToTrash: { url in
                let destination = trashURL.appendingPathComponent(url.lastPathComponent)
                try FileManager.default.moveItem(at: url, to: destination)
                return destination
            }
        )

        let result = try installer.install(packageURL: archiveURL, replacing: makeAppRecord(path: destinationURL))

        XCTAssertEqual(result, .installed(destinationURL))
        XCTAssertEqual(try version(at: destinationURL), "2.0")
        XCTAssertTrue(FileManager.default.fileExists(atPath: trashURL.appendingPathComponent("Test.app").path))
    }

    func testRejectsAppWithUnexpectedBundleIdentifier() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let sourceRoot = root.appendingPathComponent("Source", isDirectory: true)
        let destinationURL = root.appendingPathComponent("Applications/Test.app", isDirectory: true)
        let archiveURL = root.appendingPathComponent("Test.zip")
        try makeApp(at: sourceRoot.appendingPathComponent("Test.app"), bundleIdentifier: "com.example.other", version: "2.0")
        try makeApp(at: destinationURL, bundleIdentifier: "com.example.test", version: "1.0")
        try Data().write(to: archiveURL)
        defer { try? FileManager.default.removeItem(at: root) }

        let runner = StubDownloadedAppCommandRunner { _, arguments in
            try FileManager.default.copyItem(
                at: sourceRoot.appendingPathComponent("Test.app"),
                to: URL(fileURLWithPath: arguments.last!).appendingPathComponent("Test.app")
            )
            return ""
        }
        let installer = DownloadedAppInstaller(commandRunner: runner)

        XCTAssertThrowsError(
            try installer.install(packageURL: archiveURL, replacing: makeAppRecord(path: destinationURL))
        ) { error in
            XCTAssertEqual(
                error as? DownloadedAppInstallerError,
                .bundleIdentifierMismatch(expected: "com.example.test", actual: "com.example.other")
            )
        }
        XCTAssertEqual(try version(at: destinationURL), "1.0")
    }

    func testQuitsRunningAppBeforeReplacementAndReopensAfterwards() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let sourceRoot = root.appendingPathComponent("Source", isDirectory: true)
        let destinationURL = root.appendingPathComponent("Applications/Test.app", isDirectory: true)
        let archiveURL = root.appendingPathComponent("Test.zip")
        try makeApp(at: sourceRoot.appendingPathComponent("Test.app"), bundleIdentifier: "com.example.test", version: "2.0")
        try makeApp(at: destinationURL, bundleIdentifier: "com.example.test", version: "1.0")
        try Data().write(to: archiveURL)
        defer { try? FileManager.default.removeItem(at: root) }

        let trashURL = root.appendingPathComponent("Trash", isDirectory: true)
        try FileManager.default.createDirectory(at: trashURL, withIntermediateDirectories: true)
        let events = EventRecorder()
        let lifecycleManager = StubInstalledApplicationLifecycleManager(
            isRunningHandler: { _ in true },
            requestQuitHandler: { _ in
                events.append("quit")
                XCTAssertEqual(try? self.version(at: destinationURL), "1.0")
            },
            reopenHandler: { _ in
                events.append("reopen")
                XCTAssertEqual(try self.version(at: destinationURL), "2.0")
            }
        )
        let runner = StubDownloadedAppCommandRunner { _, arguments in
            try FileManager.default.copyItem(
                at: sourceRoot.appendingPathComponent("Test.app"),
                to: URL(fileURLWithPath: arguments.last!).appendingPathComponent("Test.app")
            )
            return ""
        }
        let installer = DownloadedAppInstaller(
            commandRunner: runner,
            lifecycleManager: lifecycleManager,
            moveToTrash: { url in
                events.append("trash")
                let destination = trashURL.appendingPathComponent(url.lastPathComponent)
                try FileManager.default.moveItem(at: url, to: destination)
                return destination
            }
        )

        let progressEvents = InstallProgressRecorder()
        let result = try installer.install(
            packageURL: archiveURL,
            replacing: makeAppRecord(path: destinationURL)
        ) { progress in
            progressEvents.append(progress)
        }

        XCTAssertEqual(result, .installed(destinationURL))
        XCTAssertEqual(events.values, ["quit", "trash", "reopen"])
        XCTAssertEqual(
            progressEvents.values,
            [.requestingQuit, .waitingForQuit, .replacingApplication, .reopeningApplication]
        )
    }

    func testKeepsOldAppWhenRunningAppCannotQuit() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let sourceRoot = root.appendingPathComponent("Source", isDirectory: true)
        let destinationURL = root.appendingPathComponent("Applications/Test.app", isDirectory: true)
        let archiveURL = root.appendingPathComponent("Test.zip")
        try makeApp(at: sourceRoot.appendingPathComponent("Test.app"), bundleIdentifier: "com.example.test", version: "2.0")
        try makeApp(at: destinationURL, bundleIdentifier: "com.example.test", version: "1.0")
        try Data().write(to: archiveURL)
        defer { try? FileManager.default.removeItem(at: root) }

        let lifecycleManager = StubInstalledApplicationLifecycleManager(
            isRunningHandler: { _ in true },
            waitHandler: { app, _ in
                throw DownloadedAppInstallerError.unableToQuitApplication(app.name)
            }
        )
        let runner = StubDownloadedAppCommandRunner { _, arguments in
            try FileManager.default.copyItem(
                at: sourceRoot.appendingPathComponent("Test.app"),
                to: URL(fileURLWithPath: arguments.last!).appendingPathComponent("Test.app")
            )
            return ""
        }
        let installer = DownloadedAppInstaller(
            commandRunner: runner,
            lifecycleManager: lifecycleManager,
            moveToTrash: { url in
                XCTAssertNotEqual(url.standardizedFileURL, destinationURL.standardizedFileURL)
                return nil
            }
        )

        XCTAssertThrowsError(
            try installer.install(packageURL: archiveURL, replacing: makeAppRecord(path: destinationURL))
        ) { error in
            XCTAssertEqual(
                error as? DownloadedAppInstallerError,
                .unableToQuitApplication("Test")
            )
        }
        XCTAssertEqual(try version(at: destinationURL), "1.0")
    }

    private func makeAppRecord(path: URL) -> AppRecord {
        AppRecord(
            id: "com.example.test",
            name: "Test",
            bundleIdentifier: "com.example.test",
            shortVersion: "1.0",
            buildVersion: "1",
            path: path,
            sizeBytes: 1,
            installSource: .manual(reason: "self")
        )
    }

    private func makeApp(
        at url: URL,
        bundleIdentifier: String,
        version: String,
        executableName: String? = nil
    ) throws {
        let contentsURL = url.appendingPathComponent("Contents", isDirectory: true)
        try FileManager.default.createDirectory(at: contentsURL, withIntermediateDirectories: true)
        var plist: [String: Any] = [
            "CFBundleName": "Test",
            "CFBundleIdentifier": bundleIdentifier,
            "CFBundleShortVersionString": version,
            "CFBundleVersion": version,
        ]
        if let executableName {
            plist["CFBundleExecutable"] = executableName
        }
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try data.write(to: contentsURL.appendingPathComponent("Info.plist"))
    }

    private func version(at url: URL) throws -> String? {
        let data = try Data(contentsOf: url.appendingPathComponent("Contents/Info.plist"))
        let plist = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        return plist?["CFBundleShortVersionString"] as? String
    }
}

private struct StubDownloadedAppCommandRunner: CommandRunning {
    let handler: @Sendable (String, [String]) throws -> String

    init(handler: @escaping @Sendable (String, [String]) throws -> String) {
        self.handler = handler
    }

    func run(_ executable: String, arguments: [String]) throws -> String {
        try handler(executable, arguments)
    }
}

private final class EventRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String] = []

    var values: [String] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func append(_ value: String) {
        lock.lock()
        storage.append(value)
        lock.unlock()
    }
}

private final class InstallProgressRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [DownloadedAppInstallProgress] = []

    var values: [DownloadedAppInstallProgress] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func append(_ value: DownloadedAppInstallProgress) {
        lock.lock()
        storage.append(value)
        lock.unlock()
    }
}

private struct StubInstalledApplicationLifecycleManager: InstalledApplicationLifecycleManaging {
    let isRunningHandler: @Sendable (AppRecord) -> Bool
    let requestQuitHandler: @Sendable (AppRecord) -> Void
    let waitHandler: @Sendable (AppRecord, TimeInterval) throws -> Void
    let reopenHandler: @Sendable (AppRecord) throws -> Void

    init(
        isRunningHandler: @escaping @Sendable (AppRecord) -> Bool,
        requestQuitHandler: @escaping @Sendable (AppRecord) -> Void = { _ in },
        waitHandler: @escaping @Sendable (AppRecord, TimeInterval) throws -> Void = { _, _ in },
        reopenHandler: @escaping @Sendable (AppRecord) throws -> Void = { _ in }
    ) {
        self.isRunningHandler = isRunningHandler
        self.requestQuitHandler = requestQuitHandler
        self.waitHandler = waitHandler
        self.reopenHandler = reopenHandler
    }

    func isRunning(_ app: AppRecord) -> Bool {
        isRunningHandler(app)
    }

    func requestQuit(_ app: AppRecord) {
        requestQuitHandler(app)
    }

    func waitUntilTerminated(_ app: AppRecord, timeout: TimeInterval) throws {
        try waitHandler(app, timeout)
    }

    func reopen(_ app: AppRecord) throws {
        try reopenHandler(app)
    }
}
