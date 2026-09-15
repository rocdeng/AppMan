import AppKit
import Foundation

public enum DownloadedAppInstallResult: Equatable, Sendable {
    case installed(URL)
    case requiresManualInstallation
}

public protocol DownloadedAppInstalling: Sendable {
    func install(
        packageURL: URL,
        replacing app: AppRecord,
        progress: @escaping @Sendable (DownloadedAppInstallProgress) -> Void
    ) throws -> DownloadedAppInstallResult
}

public extension DownloadedAppInstalling {
    func install(packageURL: URL, replacing app: AppRecord) throws -> DownloadedAppInstallResult {
        try install(packageURL: packageURL, replacing: app) { _ in }
    }
}

public enum DownloadedAppInstallProgress: Equatable, Sendable {
    case requestingQuit
    case waitingForQuit
    case replacingApplication
    case reopeningApplication
}

public enum DownloadedAppInstallerError: LocalizedError, Equatable {
    case invalidDiskImage
    case bundleIdentifierMismatch(expected: String, actual: String?)
    case unableToQuitApplication(String)
    case unableToReopenApplication(String)
    case unableToReplaceApplication(String)

    public var errorDescription: String? {
        switch self {
        case .invalidDiskImage:
            return "无法挂载磁盘镜像"
        case let .bundleIdentifierMismatch(expected, actual):
            return "安装包中的 App 标识不匹配：应为 \(expected)，实际为 \(actual ?? "未知")"
        case let .unableToQuitApplication(name):
            return "\(name) 未能在规定时间内完全退出，已取消替换"
        case let .unableToReopenApplication(name):
            return "已完成替换，但无法重新打开 \(name)"
        case let .unableToReplaceApplication(message):
            return "无法覆盖旧版本 App：\(message)"
        }
    }
}

public protocol InstalledApplicationLifecycleManaging: Sendable {
    func isRunning(_ app: AppRecord) -> Bool
    func requestQuit(_ app: AppRecord)
    func waitUntilTerminated(_ app: AppRecord, timeout: TimeInterval) throws
    func reopen(_ app: AppRecord) throws
}

public struct InstalledApplicationLifecycleManager: InstalledApplicationLifecycleManaging, Sendable {
    public init() {}

    public func isRunning(_ app: AppRecord) -> Bool {
        !matchingMainApplications(for: app).isEmpty
    }

    public func requestQuit(_ app: AppRecord) {
        let mainApplications = matchingMainApplications(for: app).filter {
            $0.bundleIdentifier == app.bundleIdentifier
                || $0.bundleURL?.standardizedFileURL == app.path.standardizedFileURL
        }
        for runningApplication in mainApplications {
            _ = runningApplication.terminate()
        }
    }

    public func waitUntilTerminated(_ app: AppRecord, timeout: TimeInterval) throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if matchingMainApplications(for: app).isEmpty {
                return
            }
            Thread.sleep(forTimeInterval: 0.1)
        }

        throw DownloadedAppInstallerError.unableToQuitApplication(app.name)
    }

    public func reopen(_ app: AppRecord) throws {
        guard NSWorkspace.shared.open(app.path) else {
            throw DownloadedAppInstallerError.unableToReopenApplication(app.name)
        }
    }

    private func matchingMainApplications(for app: AppRecord) -> [NSRunningApplication] {
        return NSWorkspace.shared.runningApplications.filter { runningApplication in
            Self.isMainApplication(
                bundleIdentifier: runningApplication.bundleIdentifier,
                executableURL: runningApplication.executableURL,
                app: app
            )
        }
    }

    static func isMainApplication(
        bundleIdentifier: String?,
        executableURL: URL?,
        app: AppRecord
    ) -> Bool {
        if let expectedBundleIdentifier = app.bundleIdentifier,
           bundleIdentifier == expectedBundleIdentifier {
            return true
        }

        guard let expectedExecutableURL = mainExecutableURL(for: app),
              let executableURL else {
            return false
        }
        return executableURL.standardizedFileURL == expectedExecutableURL.standardizedFileURL
    }

    private static func mainExecutableURL(for app: AppRecord) -> URL? {
        let infoPlistURL = app.path.appendingPathComponent("Contents/Info.plist")
        guard let data = try? Data(contentsOf: infoPlistURL),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil),
              let dictionary = plist as? [String: Any],
              let executableName = dictionary["CFBundleExecutable"] as? String,
              !executableName.isEmpty else {
            return nil
        }
        return app.path.appendingPathComponent("Contents/MacOS/\(executableName)")
    }
}

public struct DownloadedAppInstaller: DownloadedAppInstalling, @unchecked Sendable {
    private let fileManager: FileManager
    private let commandRunner: any CommandRunning
    private let moveToTrash: @Sendable (URL) throws -> URL?
    private let lifecycleManager: any InstalledApplicationLifecycleManaging
    private let quitTimeout: TimeInterval

    public init(
        fileManager: FileManager = .default,
        commandRunner: any CommandRunning = ProcessCommandRunner(),
        lifecycleManager: any InstalledApplicationLifecycleManaging = InstalledApplicationLifecycleManager(),
        quitTimeout: TimeInterval = 10,
        moveToTrash: (@Sendable (URL) throws -> URL?)? = nil
    ) {
        self.fileManager = fileManager
        self.commandRunner = commandRunner
        self.lifecycleManager = lifecycleManager
        self.quitTimeout = quitTimeout
        self.moveToTrash = moveToTrash ?? { url in
            var resultingURL: NSURL?
            try FileManager.default.trashItem(at: url, resultingItemURL: &resultingURL)
            return resultingURL as URL?
        }
    }

    public func install(
        packageURL: URL,
        replacing app: AppRecord,
        progress: @escaping @Sendable (DownloadedAppInstallProgress) -> Void
    ) throws -> DownloadedAppInstallResult {
        switch packageURL.pathExtension.lowercased() {
        case "zip":
            return try installFromArchive(packageURL, replacing: app, progress: progress)
        case "dmg":
            return try installFromDiskImage(packageURL, replacing: app, progress: progress)
        default:
            return .requiresManualInstallation
        }
    }

    private func installFromArchive(
        _ archiveURL: URL,
        replacing app: AppRecord,
        progress: @escaping @Sendable (DownloadedAppInstallProgress) -> Void
    ) throws -> DownloadedAppInstallResult {
        let extractionURL = fileManager.temporaryDirectory
            .appendingPathComponent("AppMan-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: extractionURL, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: extractionURL) }

        _ = try commandRunner.run("ditto", arguments: ["-x", "-k", archiveURL.path, extractionURL.path])
        guard let appBundleURL = matchingAppBundle(in: [extractionURL], for: app) else {
            return .requiresManualInstallation
        }
        return try replaceApplication(with: appBundleURL, replacing: app, progress: progress)
    }

    private func installFromDiskImage(
        _ diskImageURL: URL,
        replacing app: AppRecord,
        progress: @escaping @Sendable (DownloadedAppInstallProgress) -> Void
    ) throws -> DownloadedAppInstallResult {
        let output = try commandRunner.run(
            "hdiutil",
            arguments: ["attach", "-nobrowse", "-readonly", "-plist", diskImageURL.path]
        )
        let mountURLs = try Self.mountURLs(fromPropertyList: output)
        guard !mountURLs.isEmpty else {
            throw DownloadedAppInstallerError.invalidDiskImage
        }
        defer {
            for mountURL in mountURLs.reversed() {
                _ = try? commandRunner.run("hdiutil", arguments: ["detach", mountURL.path])
            }
        }

        guard let appBundleURL = matchingAppBundle(in: mountURLs, for: app) else {
            return .requiresManualInstallation
        }
        return try replaceApplication(with: appBundleURL, replacing: app, progress: progress)
    }

    private func replaceApplication(
        with sourceURL: URL,
        replacing app: AppRecord,
        progress: @escaping @Sendable (DownloadedAppInstallProgress) -> Void
    ) throws -> DownloadedAppInstallResult {
        let actualBundleIdentifier = bundleIdentifier(at: sourceURL)
        if let expectedBundleIdentifier = app.bundleIdentifier,
           actualBundleIdentifier != expectedBundleIdentifier {
            throw DownloadedAppInstallerError.bundleIdentifierMismatch(
                expected: expectedBundleIdentifier,
                actual: actualBundleIdentifier
            )
        }

        let destinationURL = app.path
        let parentURL = destinationURL.deletingLastPathComponent()
        let stagingURL = parentURL.appendingPathComponent(
            ".AppMan-\(UUID().uuidString)-\(destinationURL.lastPathComponent)",
            isDirectory: true
        )

        do {
            try fileManager.copyItem(at: sourceURL, to: stagingURL)
            defer {
                if fileManager.fileExists(atPath: stagingURL.path) {
                    _ = try? moveToTrash(stagingURL)
                }
            }
            if let expectedBundleIdentifier = app.bundleIdentifier,
               bundleIdentifier(at: stagingURL) != expectedBundleIdentifier {
                throw DownloadedAppInstallerError.bundleIdentifierMismatch(
                    expected: expectedBundleIdentifier,
                    actual: bundleIdentifier(at: stagingURL)
                )
            }

            let wasRunning = lifecycleManager.isRunning(app)
            if wasRunning {
                progress(.requestingQuit)
                lifecycleManager.requestQuit(app)
                progress(.waitingForQuit)
                try lifecycleManager.waitUntilTerminated(app, timeout: quitTimeout)
            }

            var trashedOriginalURL: URL?
            progress(.replacingApplication)
            if fileManager.fileExists(atPath: destinationURL.path) {
                trashedOriginalURL = try moveToTrash(destinationURL)
            }

            do {
                try fileManager.moveItem(at: stagingURL, to: destinationURL)
            } catch {
                if let trashedOriginalURL,
                   !fileManager.fileExists(atPath: destinationURL.path) {
                    try? fileManager.moveItem(at: trashedOriginalURL, to: destinationURL)
                }
                throw error
            }

            if wasRunning {
                progress(.reopeningApplication)
                try lifecycleManager.reopen(app)
            }
        } catch let error as DownloadedAppInstallerError {
            throw error
        } catch {
            throw DownloadedAppInstallerError.unableToReplaceApplication(error.localizedDescription)
        }

        return .installed(destinationURL)
    }

    private func matchingAppBundle(in roots: [URL], for app: AppRecord) -> URL? {
        let candidates = roots.flatMap(appBundleURLs(in:))
        if let bundleIdentifier = app.bundleIdentifier,
           let match = candidates.first(where: { self.bundleIdentifier(at: $0) == bundleIdentifier }) {
            return match
        }

        return candidates.first {
            $0.lastPathComponent.localizedCaseInsensitiveCompare(app.path.lastPathComponent) == .orderedSame
                || $0.deletingPathExtension().lastPathComponent.localizedCaseInsensitiveCompare(app.name) == .orderedSame
        }
    }

    private func appBundleURLs(in rootURL: URL) -> [URL] {
        if rootURL.pathExtension.lowercased() == "app" {
            return [rootURL]
        }

        guard let enumerator = fileManager.enumerator(
            at: rootURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        var appURLs: [URL] = []
        for case let url as URL in enumerator where url.pathExtension.lowercased() == "app" {
            appURLs.append(url)
            enumerator.skipDescendants()
        }
        return appURLs
    }

    private func bundleIdentifier(at appURL: URL) -> String? {
        let infoPlistURL = appURL
            .appendingPathComponent("Contents", isDirectory: true)
            .appendingPathComponent("Info.plist")
        guard let data = try? Data(contentsOf: infoPlistURL),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil),
              let dictionary = plist as? [String: Any] else {
            return nil
        }
        return dictionary["CFBundleIdentifier"] as? String
    }

    private static func mountURLs(fromPropertyList output: String) throws -> [URL] {
        guard let data = output.data(using: .utf8),
              let plist = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let entities = plist["system-entities"] as? [[String: Any]] else {
            throw DownloadedAppInstallerError.invalidDiskImage
        }

        return entities.compactMap { entity in
            guard let mountPoint = entity["mount-point"] as? String else {
                return nil
            }
            return URL(fileURLWithPath: mountPoint, isDirectory: true)
        }
    }
}
