# AppMan Scanner Foundation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a runnable SwiftUI macOS foundation that scans installed apps, reads app metadata, identifies basic install channels, and displays the result.

**Architecture:** The first implementation slice keeps risky operations out of scope. Core scanning and channel detection live in a small Swift package with unit tests, while the macOS app consumes those services through a simple view model. Shell integrations are wrapped behind protocols so tests can use deterministic fixtures instead of calling `brew` or `mas`.

**Tech Stack:** Swift 5.9+, Swift Package Manager, SwiftUI, XCTest, FileManager, PropertyListSerialization, `/usr/bin/mdls` optional metadata probing.

---

## Scope

| Included | Excluded from this plan |
|---|---|
| Swift package foundation | Uninstalling apps |
| SwiftUI macOS app shell | Residual file cleanup |
| App bundle metadata scanner | Quarantine and restore |
| Homebrew/MAS/manual channel labels | Executing updates |
| Unit tests with fixture `.app` bundles | Website search and homepage trust records |

This plan covers acceptance criteria 1 and the foundation of criterion 2 from the design spec.

## File Structure

| Path | Responsibility |
|---|---|
| `Package.swift` | Swift package definition for core library, tests, and app executable |
| `Sources/AppManCore/AppRecord.swift` | Immutable app metadata and install source models |
| `Sources/AppManCore/AppBundleReader.swift` | Read `.app/Contents/Info.plist`, size, and basic metadata |
| `Sources/AppManCore/AppScanner.swift` | Enumerate `/Applications` and `~/Applications` or injected scan roots |
| `Sources/AppManCore/CommandRunning.swift` | Small command runner protocol and production implementation |
| `Sources/AppManCore/HomebrewCaskDetector.swift` | Detect Homebrew Cask apps from injected command output |
| `Sources/AppManCore/MacAppStoreDetector.swift` | Detect MAS apps from receipt metadata |
| `Sources/AppManCore/InstallSourceResolver.swift` | Combine channel detectors and fall back to manual |
| `Sources/AppManApp/AppManApp.swift` | SwiftUI app entry point |
| `Sources/AppManApp/AppListView.swift` | Main app list and detail UI |
| `Sources/AppManApp/AppListViewModel.swift` | UI state and scan orchestration |
| `Tests/AppManCoreTests/AppBundleReaderTests.swift` | Metadata parsing tests |
| `Tests/AppManCoreTests/AppScannerTests.swift` | Scan root enumeration tests |
| `Tests/AppManCoreTests/InstallSourceResolverTests.swift` | Channel detection tests |
| `Tests/AppManCoreTests/Fixtures/` | Minimal fake `.app` bundles and command output fixtures |

## Task 1: Create Swift Package Skeleton

**Files:**
- Create: `Package.swift`
- Create: `Sources/AppManCore/AppRecord.swift`
- Create: `Tests/AppManCoreTests/AppRecordTests.swift`
- Create: `Tests/AppManCoreTests/Fixtures/.gitkeep`

- [ ] **Step 1: Create the package manifest**

Create `Package.swift`:

```swift
// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "AppMan",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .library(name: "AppManCore", targets: ["AppManCore"]),
        .executable(name: "AppMan", targets: ["AppManApp"])
    ],
    targets: [
        .target(name: "AppManCore"),
        .executableTarget(
            name: "AppManApp",
            dependencies: ["AppManCore"]
        ),
        .testTarget(
            name: "AppManCoreTests",
            dependencies: ["AppManCore"],
            resources: [
                .copy("Fixtures")
            ]
        )
    ]
)
```

- [ ] **Step 2: Add the core model**

Create the fixture directory marker so SwiftPM can copy `Tests/AppManCoreTests/Fixtures` before real fixtures are added:

```bash
mkdir -p Tests/AppManCoreTests/Fixtures
touch Tests/AppManCoreTests/Fixtures/.gitkeep
```

- [ ] **Step 3: Add the core model**

Create `Sources/AppManCore/AppRecord.swift`:

```swift
import Foundation

public struct AppRecord: Identifiable, Equatable, Sendable {
    public let id: String
    public let name: String
    public let bundleIdentifier: String?
    public let shortVersion: String?
    public let buildVersion: String?
    public let path: URL
    public let sizeBytes: Int64
    public var installSource: InstallSource

    public init(
        id: String,
        name: String,
        bundleIdentifier: String?,
        shortVersion: String?,
        buildVersion: String?,
        path: URL,
        sizeBytes: Int64,
        installSource: InstallSource = .manual(reason: "尚未识别到安装渠道")
    ) {
        self.id = id
        self.name = name
        self.bundleIdentifier = bundleIdentifier
        self.shortVersion = shortVersion
        self.buildVersion = buildVersion
        self.path = path
        self.sizeBytes = sizeBytes
        self.installSource = installSource
    }
}

public enum InstallSource: Equatable, Sendable {
    case homebrewCask(token: String)
    case macAppStore
    case sparkle(feedURL: URL)
    case manual(reason: String)

    public var displayName: String {
        switch self {
        case .homebrewCask:
            return "Homebrew Cask"
        case .macAppStore:
            return "Mac App Store"
        case .sparkle:
            return "Sparkle"
        case .manual:
            return "手动/未知"
        }
    }
}
```

- [ ] **Step 4: Add a model test**

Create `Tests/AppManCoreTests/AppRecordTests.swift`:

```swift
import XCTest
@testable import AppManCore

final class AppRecordTests: XCTestCase {
    func testManualInstallSourceDisplayName() {
        let source = InstallSource.manual(reason: "没有找到安装渠道证据")
        XCTAssertEqual(source.displayName, "手动/未知")
    }

    func testHomebrewInstallSourceDisplayName() {
        let source = InstallSource.homebrewCask(token: "visual-studio-code")
        XCTAssertEqual(source.displayName, "Homebrew Cask")
    }
}
```

- [ ] **Step 5: Run tests**

Run:

```bash
swift test
```

Expected: tests pass.

- [ ] **Step 6: Commit**

```bash
git add Package.swift Sources/AppManCore/AppRecord.swift Tests/AppManCoreTests/AppRecordTests.swift Tests/AppManCoreTests/Fixtures/.gitkeep
git commit -m "Add Swift package foundation"
```

## Task 2: Implement App Bundle Metadata Reader

**Files:**
- Create: `Sources/AppManCore/AppBundleReader.swift`
- Create fixture: `Tests/AppManCoreTests/Fixtures/TestApp.app/Contents/Info.plist`
- Create: `Tests/AppManCoreTests/AppBundleReaderTests.swift`

- [ ] **Step 1: Add fixture app metadata**

Create `Tests/AppManCoreTests/Fixtures/TestApp.app/Contents/Info.plist`:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDisplayName</key>
    <string>测试应用</string>
    <key>CFBundleIdentifier</key>
    <string>com.example.testapp</string>
    <key>CFBundleShortVersionString</key>
    <string>1.2.3</string>
    <key>CFBundleVersion</key>
    <string>123</string>
</dict>
</plist>
```

- [ ] **Step 2: Write failing metadata tests**

Create `Tests/AppManCoreTests/AppBundleReaderTests.swift`:

```swift
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

    private func fixtureURL(_ name: String) throws -> URL {
        let bundle = Bundle.module
        let fixturesURL = bundle.resourceURL!.appendingPathComponent("Fixtures", isDirectory: true)
        let url = fixturesURL.appendingPathComponent(name, isDirectory: true)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        return url
    }
}
```

- [ ] **Step 3: Run tests and verify failure**

Run:

```bash
swift test --filter AppBundleReaderTests
```

Expected: FAIL because `AppBundleReader` does not exist.

- [ ] **Step 4: Implement metadata reader**

Create `Sources/AppManCore/AppBundleReader.swift`:

```swift
import Foundation

public enum AppBundleReaderError: Error, Equatable {
    case missingInfoPlist(URL)
    case unreadableInfoPlist(URL)
}

public struct AppBundleReader: Sendable {
    private let fileManager: FileManager

    public init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    public func readApp(at appURL: URL) throws -> AppRecord {
        let infoPlistURL = appURL
            .appendingPathComponent("Contents", isDirectory: true)
            .appendingPathComponent("Info.plist")

        guard fileManager.fileExists(atPath: infoPlistURL.path) else {
            throw AppBundleReaderError.missingInfoPlist(infoPlistURL)
        }

        let data = try Data(contentsOf: infoPlistURL)
        guard
            let plist = try PropertyListSerialization.propertyList(from: data) as? [String: Any]
        else {
            throw AppBundleReaderError.unreadableInfoPlist(infoPlistURL)
        }

        let displayName = plist["CFBundleDisplayName"] as? String
        let bundleName = plist["CFBundleName"] as? String
        let fallbackName = appURL.deletingPathExtension().lastPathComponent
        let name = displayName ?? bundleName ?? fallbackName

        let bundleIdentifier = plist["CFBundleIdentifier"] as? String
        let shortVersion = plist["CFBundleShortVersionString"] as? String
        let buildVersion = plist["CFBundleVersion"] as? String
        let sizeBytes = directorySize(at: appURL)

        return AppRecord(
            id: bundleIdentifier ?? appURL.path,
            name: name,
            bundleIdentifier: bundleIdentifier,
            shortVersion: shortVersion,
            buildVersion: buildVersion,
            path: appURL,
            sizeBytes: sizeBytes
        )
    }

    private func directorySize(at url: URL) -> Int64 {
        guard let enumerator = fileManager.enumerator(
            at: url,
            includingPropertiesForKeys: [.totalFileAllocatedSizeKey, .fileAllocatedSizeKey],
            options: [.skipsHiddenFiles]
        ) else {
            return 0
        }

        var size: Int64 = 0
        for case let fileURL as URL in enumerator {
            let values = try? fileURL.resourceValues(forKeys: [.totalFileAllocatedSizeKey, .fileAllocatedSizeKey])
            size += Int64(values?.totalFileAllocatedSize ?? values?.fileAllocatedSize ?? 0)
        }
        return size
    }
}
```

- [ ] **Step 5: Run tests**

Run:

```bash
swift test --filter AppBundleReaderTests
```

Expected: tests pass.

- [ ] **Step 6: Commit**

```bash
git add Sources/AppManCore/AppBundleReader.swift Tests/AppManCoreTests/AppBundleReaderTests.swift Tests/AppManCoreTests/Fixtures/TestApp.app/Contents/Info.plist
git commit -m "Add app bundle metadata reader"
```

## Task 3: Implement App Scanner

**Files:**
- Create: `Sources/AppManCore/AppScanner.swift`
- Create: `Tests/AppManCoreTests/AppScannerTests.swift`

- [ ] **Step 1: Write scanner tests**

Create `Tests/AppManCoreTests/AppScannerTests.swift`:

```swift
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

        XCTAssertEqual(records.map(\\.name).sorted(), ["Alpha", "Beta"])
        XCTAssertEqual(records.map(\\.bundleIdentifier).compactMap { $0 }.sorted(), [
            "com.example.alpha",
            "com.example.beta"
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
            <string>\\(appName)</string>
            <key>CFBundleIdentifier</key>
            <string>\\(bundleID)</string>
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
```

- [ ] **Step 2: Run tests and verify failure**

Run:

```bash
swift test --filter AppScannerTests
```

Expected: FAIL because `AppScanner` does not exist.

- [ ] **Step 3: Implement scanner**

Create `Sources/AppManCore/AppScanner.swift`:

```swift
import Foundation

public struct AppScanner: Sendable {
    private let scanRoots: [URL]
    private let fileManager: FileManager
    private let bundleReader: AppBundleReader

    public init(
        scanRoots: [URL] = AppScanner.defaultScanRoots(),
        fileManager: FileManager = .default,
        bundleReader: AppBundleReader = AppBundleReader()
    ) {
        self.scanRoots = scanRoots
        self.fileManager = fileManager
        self.bundleReader = bundleReader
    }

    public func scanInstalledApps() throws -> [AppRecord] {
        var records: [AppRecord] = []

        for root in scanRoots {
            guard fileManager.fileExists(atPath: root.path) else {
                continue
            }

            let children = try fileManager.contentsOfDirectory(
                at: root,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            )

            for child in children where child.pathExtension == "app" {
                guard (try? child.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else {
                    continue
                }

                if let record = try? bundleReader.readApp(at: child) {
                    records.append(record)
                }
            }
        }

        return records.sorted { left, right in
            left.name.localizedCaseInsensitiveCompare(right.name) == .orderedAscending
        }
    }

    public static func defaultScanRoots() -> [URL] {
        var roots = [URL(fileURLWithPath: "/Applications", isDirectory: true)]
        if let userApplications = FileManager.default.urls(for: .applicationDirectory, in: .userDomainMask).first {
            roots.append(userApplications)
        }
        return roots
    }
}
```

- [ ] **Step 4: Run scanner tests**

Run:

```bash
swift test --filter AppScannerTests
```

Expected: tests pass.

- [ ] **Step 5: Run all tests**

Run:

```bash
swift test
```

Expected: all tests pass.

- [ ] **Step 6: Commit**

```bash
git add Sources/AppManCore/AppScanner.swift Tests/AppManCoreTests/AppScannerTests.swift
git commit -m "Add installed app scanner"
```

## Task 4: Add Command Runner and Homebrew Detector

**Files:**
- Create: `Sources/AppManCore/CommandRunning.swift`
- Create: `Sources/AppManCore/HomebrewCaskDetector.swift`
- Create: `Tests/AppManCoreTests/HomebrewCaskDetectorTests.swift`

- [ ] **Step 1: Write Homebrew detector tests**

Create `Tests/AppManCoreTests/HomebrewCaskDetectorTests.swift`:

```swift
import XCTest
@testable import AppManCore

final class HomebrewCaskDetectorTests: XCTestCase {
    func testDetectsAppByBundleIdentifierFromBrewInfoJSON() throws {
        let runner = StubCommandRunner(outputs: [
            "brew info --cask --json=v2": """
            {
              "casks": [
                {
                  "token": "visual-studio-code",
                  "artifacts": [
                    { "app": ["Visual Studio Code.app"] }
                  ],
                  "installed": "1.100.0"
                }
              ]
            }
            """
        ])
        let detector = HomebrewCaskDetector(commandRunner: runner)
        let app = AppRecord(
            id: "com.microsoft.VSCode",
            name: "Visual Studio Code",
            bundleIdentifier: "com.microsoft.VSCode",
            shortVersion: "1.100.0",
            buildVersion: nil,
            path: URL(fileURLWithPath: "/Applications/Visual Studio Code.app"),
            sizeBytes: 1
        )

        let source = try detector.detectInstallSource(for: app)

        XCTAssertEqual(source, .homebrewCask(token: "visual-studio-code"))
    }

    func testReturnsNilWhenBrewIsUnavailable() throws {
        let runner = StubCommandRunner(error: CommandError.executableNotFound("brew"))
        let detector = HomebrewCaskDetector(commandRunner: runner)
        let app = AppRecord(
            id: "com.example.manual",
            name: "Manual",
            bundleIdentifier: "com.example.manual",
            shortVersion: nil,
            buildVersion: nil,
            path: URL(fileURLWithPath: "/Applications/Manual.app"),
            sizeBytes: 1
        )

        let source = try detector.detectInstallSource(for: app)

        XCTAssertNil(source)
    }
}

private struct StubCommandRunner: CommandRunning {
    let outputs: [String: String]
    let error: Error?

    init(outputs: [String: String] = [:], error: Error? = nil) {
        self.outputs = outputs
        self.error = error
    }

    func run(_ executable: String, arguments: [String]) throws -> String {
        if let error {
            throw error
        }
        let key = ([executable] + arguments).joined(separator: " ")
        return outputs[key] ?? ""
    }
}
```

- [ ] **Step 2: Run tests and verify failure**

Run:

```bash
swift test --filter HomebrewCaskDetectorTests
```

Expected: FAIL because `CommandRunning` and `HomebrewCaskDetector` do not exist.

- [ ] **Step 3: Add command runner**

Create `Sources/AppManCore/CommandRunning.swift`:

```swift
import Foundation

public protocol CommandRunning: Sendable {
    func run(_ executable: String, arguments: [String]) throws -> String
}

public enum CommandError: Error, Equatable {
    case executableNotFound(String)
    case failed(status: Int32, stderr: String)
}

public struct ProcessCommandRunner: CommandRunning {
    public init() {}

    public func run(_ executable: String, arguments: [String]) throws -> String {
        guard let executableURL = findExecutable(named: executable) else {
            throw CommandError.executableNotFound(executable)
        }

        let process = Process()
        process.executableURL = executableURL
        process.arguments = arguments

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr

        try process.run()
        process.waitUntilExit()

        let output = String(data: stdout.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let errorOutput = String(data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""

        guard process.terminationStatus == 0 else {
            throw CommandError.failed(status: process.terminationStatus, stderr: errorOutput)
        }

        return output
    }

    private func findExecutable(named name: String) -> URL? {
        let candidates = [
            "/opt/homebrew/bin/\\(name)",
            "/usr/local/bin/\\(name)",
            "/usr/bin/\\(name)",
            "/bin/\\(name)"
        ]

        return candidates
            .map { URL(fileURLWithPath: $0) }
            .first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }
}
```

- [ ] **Step 4: Add Homebrew detector**

Create `Sources/AppManCore/HomebrewCaskDetector.swift`:

```swift
import Foundation

public struct HomebrewCaskDetector: Sendable {
    private let commandRunner: CommandRunning

    public init(commandRunner: CommandRunning = ProcessCommandRunner()) {
        self.commandRunner = commandRunner
    }

    public func detectInstallSource(for app: AppRecord) throws -> InstallSource? {
        let output: String
        do {
            output = try commandRunner.run("brew", arguments: ["info", "--cask", "--json=v2"])
        } catch CommandError.executableNotFound {
            return nil
        }

        let casks = try parseCasks(from: output)
        let appFileName = app.path.lastPathComponent

        guard let token = casks.first(where: { cask in
            cask.appNames.contains(appFileName)
        })?.token else {
            return nil
        }

        return .homebrewCask(token: token)
    }

    private func parseCasks(from json: String) throws -> [BrewCask] {
        guard let data = json.data(using: .utf8), !data.isEmpty else {
            return []
        }

        let decoded = try JSONDecoder().decode(BrewInfoResponse.self, from: data)
        return decoded.casks.map { cask in
            BrewCask(
                token: cask.token,
                appNames: cask.artifacts.flatMap { artifact in
                    artifact.app?.compactMap { value in
                        if case let .string(name) = value {
                            return name
                        }
                        return nil
                    } ?? []
                }
            )
        }
    }
}

private struct BrewCask {
    let token: String
    let appNames: [String]
}

private struct BrewInfoResponse: Decodable {
    let casks: [BrewInfoCask]
}

private struct BrewInfoCask: Decodable {
    let token: String
    let artifacts: [BrewArtifact]
}

private struct BrewArtifact: Decodable {
    let app: [LossyStringValue]?
}

private enum LossyStringValue: Decodable {
    case string(String)
    case other

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let string = try? container.decode(String.self) {
            self = .string(string)
        } else {
            self = .other
        }
    }
}
```

- [ ] **Step 5: Run tests**

Run:

```bash
swift test --filter HomebrewCaskDetectorTests
```

Expected: tests pass.

- [ ] **Step 6: Commit**

```bash
git add Sources/AppManCore/CommandRunning.swift Sources/AppManCore/HomebrewCaskDetector.swift Tests/AppManCoreTests/HomebrewCaskDetectorTests.swift
git commit -m "Add Homebrew cask detector"
```

## Task 5: Add MAS and Install Source Resolver

**Files:**
- Create: `Sources/AppManCore/MacAppStoreDetector.swift`
- Create: `Sources/AppManCore/InstallSourceResolver.swift`
- Create: `Tests/AppManCoreTests/InstallSourceResolverTests.swift`

- [ ] **Step 1: Write resolver tests**

Create `Tests/AppManCoreTests/InstallSourceResolverTests.swift`:

```swift
import XCTest
@testable import AppManCore

final class InstallSourceResolverTests: XCTestCase {
    func testResolverPrefersHomebrewWhenDetected() throws {
        let app = AppRecord(
            id: "com.example.alpha",
            name: "Alpha",
            bundleIdentifier: "com.example.alpha",
            shortVersion: nil,
            buildVersion: nil,
            path: URL(fileURLWithPath: "/Applications/Alpha.app"),
            sizeBytes: 1
        )
        let resolver = InstallSourceResolver(
            homebrewDetector: StubHomebrewDetector(source: .homebrewCask(token: "alpha")),
            macAppStoreDetector: StubMacAppStoreDetector(isMacAppStoreApp: true)
        )

        let source = try resolver.resolveInstallSource(for: app)

        XCTAssertEqual(source, .homebrewCask(token: "alpha"))
    }

    func testResolverUsesMacAppStoreWhenReceiptExists() throws {
        let app = AppRecord(
            id: "com.example.store",
            name: "Store App",
            bundleIdentifier: "com.example.store",
            shortVersion: nil,
            buildVersion: nil,
            path: URL(fileURLWithPath: "/Applications/Store.app"),
            sizeBytes: 1
        )
        let resolver = InstallSourceResolver(
            homebrewDetector: StubHomebrewDetector(source: nil),
            macAppStoreDetector: StubMacAppStoreDetector(isMacAppStoreApp: true)
        )

        let source = try resolver.resolveInstallSource(for: app)

        XCTAssertEqual(source, .macAppStore)
    }

    func testResolverFallsBackToManual() throws {
        let app = AppRecord(
            id: "com.example.manual",
            name: "Manual",
            bundleIdentifier: "com.example.manual",
            shortVersion: nil,
            buildVersion: nil,
            path: URL(fileURLWithPath: "/Applications/Manual.app"),
            sizeBytes: 1
        )
        let resolver = InstallSourceResolver(
            homebrewDetector: StubHomebrewDetector(source: nil),
            macAppStoreDetector: StubMacAppStoreDetector(isMacAppStoreApp: false)
        )

        let source = try resolver.resolveInstallSource(for: app)

        XCTAssertEqual(source, .manual(reason: "没有找到 Homebrew Cask 或 Mac App Store 安装证据"))
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
```

- [ ] **Step 2: Run tests and verify failure**

Run:

```bash
swift test --filter InstallSourceResolverTests
```

Expected: FAIL because resolver and detector protocols do not exist.

- [ ] **Step 3: Update Homebrew detector protocol**

Modify `Sources/AppManCore/HomebrewCaskDetector.swift` so the top of the file becomes:

```swift
import Foundation

public protocol HomebrewDetecting: Sendable {
    func detectInstallSource(for app: AppRecord) throws -> InstallSource?
}

public struct HomebrewCaskDetector: HomebrewDetecting, Sendable {
    private let commandRunner: CommandRunning

    public init(commandRunner: CommandRunning = ProcessCommandRunner()) {
        self.commandRunner = commandRunner
    }
```

Keep the rest of the file unchanged.

- [ ] **Step 4: Add Mac App Store detector**

Create `Sources/AppManCore/MacAppStoreDetector.swift`:

```swift
import Foundation

public protocol MacAppStoreDetecting: Sendable {
    func isAppStoreApp(_ app: AppRecord) -> Bool
}

public struct MacAppStoreDetector: MacAppStoreDetecting, Sendable {
    private let fileManager: FileManager

    public init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    public func isAppStoreApp(_ app: AppRecord) -> Bool {
        let receiptURL = app.path
            .appendingPathComponent("Contents", isDirectory: true)
            .appendingPathComponent("_MASReceipt", isDirectory: true)
            .appendingPathComponent("receipt")

        return fileManager.fileExists(atPath: receiptURL.path)
    }
}
```

- [ ] **Step 5: Add install source resolver**

Create `Sources/AppManCore/InstallSourceResolver.swift`:

```swift
import Foundation

public struct InstallSourceResolver: Sendable {
    private let homebrewDetector: HomebrewDetecting
    private let macAppStoreDetector: MacAppStoreDetecting

    public init(
        homebrewDetector: HomebrewDetecting = HomebrewCaskDetector(),
        macAppStoreDetector: MacAppStoreDetecting = MacAppStoreDetector()
    ) {
        self.homebrewDetector = homebrewDetector
        self.macAppStoreDetector = macAppStoreDetector
    }

    public func resolveInstallSource(for app: AppRecord) throws -> InstallSource {
        if let source = try homebrewDetector.detectInstallSource(for: app) {
            return source
        }

        if macAppStoreDetector.isAppStoreApp(app) {
            return .macAppStore
        }

        return .manual(reason: "没有找到 Homebrew Cask 或 Mac App Store 安装证据")
    }

    public func resolveInstallSources(for apps: [AppRecord]) throws -> [AppRecord] {
        try apps.map { app in
            var resolved = app
            resolved.installSource = try resolveInstallSource(for: app)
            return resolved
        }
    }
}
```

- [ ] **Step 6: Run resolver tests**

Run:

```bash
swift test --filter InstallSourceResolverTests
```

Expected: tests pass.

- [ ] **Step 7: Run all tests**

Run:

```bash
swift test
```

Expected: all tests pass.

- [ ] **Step 8: Commit**

```bash
git add Sources/AppManCore/HomebrewCaskDetector.swift Sources/AppManCore/MacAppStoreDetector.swift Sources/AppManCore/InstallSourceResolver.swift Tests/AppManCoreTests/InstallSourceResolverTests.swift
git commit -m "Add install source resolver"
```

## Task 6: Build SwiftUI App Shell

**Files:**
- Create: `Sources/AppManApp/AppManApp.swift`
- Create: `Sources/AppManApp/AppListView.swift`
- Create: `Sources/AppManApp/AppListViewModel.swift`

- [ ] **Step 1: Add view model**

Create `Sources/AppManApp/AppListViewModel.swift`:

```swift
import AppManCore
import Foundation

@MainActor
final class AppListViewModel: ObservableObject {
    @Published private(set) var apps: [AppRecord] = []
    @Published private(set) var isScanning = false
    @Published var errorMessage: String?

    private let scanner: AppScanner
    private let sourceResolver: InstallSourceResolver

    init(
        scanner: AppScanner = AppScanner(),
        sourceResolver: InstallSourceResolver = InstallSourceResolver()
    ) {
        self.scanner = scanner
        self.sourceResolver = sourceResolver
    }

    func scan() {
        isScanning = true
        errorMessage = nil

        Task {
            do {
                let scanned = try scanner.scanInstalledApps()
                let resolved = try sourceResolver.resolveInstallSources(for: scanned)
                apps = resolved
            } catch {
                errorMessage = error.localizedDescription
            }
            isScanning = false
        }
    }
}
```

- [ ] **Step 2: Add main view**

Create `Sources/AppManApp/AppListView.swift`:

```swift
import AppManCore
import SwiftUI

struct AppListView: View {
    @StateObject private var viewModel = AppListViewModel()
    @State private var selection: AppRecord.ID?

    var body: some View {
        NavigationSplitView {
            List(viewModel.apps, selection: $selection) { app in
                VStack(alignment: .leading, spacing: 4) {
                    Text(app.name)
                        .font(.headline)
                    Text(app.installSource.displayName)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .tag(app.id)
            }
            .navigationTitle("AppMan")
            .toolbar {
                Button {
                    viewModel.scan()
                } label: {
                    Label("扫描", systemImage: "arrow.clockwise")
                }
                .disabled(viewModel.isScanning)
            }
        } detail: {
            if let app = selectedApp {
                AppDetailView(app: app)
            } else {
                ContentUnavailableView("选择一个 App", systemImage: "app.dashed")
            }
        }
        .overlay {
            if viewModel.isScanning {
                ProgressView("正在扫描")
                    .padding()
                    .background(.regularMaterial)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            }
        }
        .alert("扫描失败", isPresented: Binding(
            get: { viewModel.errorMessage != nil },
            set: { if !$0 { viewModel.errorMessage = nil } }
        )) {
            Button("好", role: .cancel) {}
        } message: {
            Text(viewModel.errorMessage ?? "")
        }
        .onAppear {
            viewModel.scan()
        }
    }

    private var selectedApp: AppRecord? {
        viewModel.apps.first { $0.id == selection }
    }
}

private struct AppDetailView: View {
    let app: AppRecord

    var body: some View {
        Form {
            LabeledContent("名称", value: app.name)
            LabeledContent("Bundle ID", value: app.bundleIdentifier ?? "未知")
            LabeledContent("版本", value: versionText)
            LabeledContent("安装渠道", value: app.installSource.displayName)
            LabeledContent("路径", value: app.path.path)
            LabeledContent("大小", value: ByteCountFormatter.string(fromByteCount: app.sizeBytes, countStyle: .file))
        }
        .formStyle(.grouped)
        .padding()
        .navigationTitle(app.name)
    }

    private var versionText: String {
        switch (app.shortVersion, app.buildVersion) {
        case let (short?, build?):
            return "\(short) (\(build))"
        case let (short?, nil):
            return short
        case let (nil, build?):
            return build
        case (nil, nil):
            return "未知"
        }
    }
}
```

- [ ] **Step 3: Add app entry point**

Create `Sources/AppManApp/AppManApp.swift`:

```swift
import SwiftUI

@main
struct AppManApp: App {
    var body: some Scene {
        WindowGroup {
            AppListView()
                .frame(minWidth: 900, minHeight: 560)
        }
    }
}
```

- [ ] **Step 4: Build app executable**

Run:

```bash
swift build
```

Expected: build succeeds.

- [ ] **Step 5: Run all tests**

Run:

```bash
swift test
```

Expected: all tests pass.

- [ ] **Step 6: Commit**

```bash
git add Sources/AppManApp/AppManApp.swift Sources/AppManApp/AppListView.swift Sources/AppManApp/AppListViewModel.swift
git commit -m "Add SwiftUI app shell"
```

## Task 7: Add Scanner CLI Smoke Test

**Files:**
- Modify: `Sources/AppManApp/AppManApp.swift`
- Create: `Scripts/smoke_scan.sh`

- [ ] **Step 1: Add a scanner-only launch argument**

Modify `Sources/AppManApp/AppManApp.swift`:

```swift
import AppManCore
import SwiftUI

@main
struct AppManApp: App {
    init() {
        if CommandLine.arguments.contains("--smoke-scan") {
            do {
                let apps = try InstallSourceResolver()
                    .resolveInstallSources(for: AppScanner().scanInstalledApps())
                print("APP_MAN_SMOKE_SCAN_COUNT=\\(apps.count)")
                exit(0)
            } catch {
                fputs("APP_MAN_SMOKE_SCAN_ERROR=\\(error)\\n", stderr)
                exit(1)
            }
        }
    }

    var body: some Scene {
        WindowGroup {
            AppListView()
                .frame(minWidth: 900, minHeight: 560)
        }
    }
}
```

- [ ] **Step 2: Add smoke script**

Create `Scripts/smoke_scan.sh`:

```bash
#!/usr/bin/env bash
set -euo pipefail

swift run AppMan --smoke-scan
```

- [ ] **Step 3: Make script executable**

Run:

```bash
chmod +x Scripts/smoke_scan.sh
```

- [ ] **Step 4: Run smoke scan**

Run:

```bash
Scripts/smoke_scan.sh
```

Expected: output contains `APP_MAN_SMOKE_SCAN_COUNT=` followed by a number greater than `0` on a normal macOS machine with installed apps.

- [ ] **Step 5: Run all tests**

Run:

```bash
swift test
```

Expected: all tests pass.

- [ ] **Step 6: Commit**

```bash
git add Sources/AppManApp/AppManApp.swift Scripts/smoke_scan.sh
git commit -m "Add scanner smoke test"
```

## Task 8: Final Verification

**Files:**
- No new files required.

- [ ] **Step 1: Run tests**

Run:

```bash
swift test
```

Expected: all tests pass.

- [ ] **Step 2: Build app**

Run:

```bash
swift build
```

Expected: build succeeds.

- [ ] **Step 3: Run scanner smoke test**

Run:

```bash
Scripts/smoke_scan.sh
```

Expected: prints `APP_MAN_SMOKE_SCAN_COUNT=<number>`.

- [ ] **Step 4: Check git status**

Run:

```bash
git status --short
```

Expected: only pre-existing untracked `AGENTS.md` remains, unless the user chose to track it.

## Plan Self-Review

| Check | Result |
|---|---|
| Spec coverage | Covers project skeleton, App scanning, metadata reading, and base channel identification. Uninstall, residual cleanup, update execution, and homepage trust records remain intentionally out of this first implementation slice. |
| Placeholder scan | No placeholder tasks are included. Each implementation step names files, code, commands, and expected results. |
| Type consistency | `AppRecord`, `InstallSource`, `AppScanner`, `AppBundleReader`, `HomebrewDetecting`, `MacAppStoreDetecting`, and `InstallSourceResolver` are introduced before use. |
| Scope check | The full design spec is too broad for one safe implementation plan, so this plan isolates the scanner foundation. |
