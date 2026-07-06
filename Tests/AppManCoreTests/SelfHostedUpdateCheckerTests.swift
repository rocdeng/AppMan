import XCTest
@testable import AppManCore

final class SelfHostedUpdateCheckerTests: XCTestCase {
    func testMarksManualAppAsPendingConfirmationWhenGoogleFindsCandidate() throws {
        let checker = SelfHostedUpdateChecker(
            sourceStore: SelfUpdateSourceStore(storeURL: temporaryURL()),
            googleSearcher: StubSelfUpdateSearcher(result: URL(string: "https://example.com/app")!),
            fetchData: { _ in Data() }
        )

        let apps = try checker.checkUpdates(for: [makeManualApp()])

        XCTAssertEqual(
            apps.first?.updateStatus,
            .needsOfficialWebsiteConfirmation(candidateURL: URL(string: "https://example.com/app")!)
        )
    }

    func testMarksManualAppAsNeedingManualInputWhenGoogleFindsNothing() throws {
        let checker = SelfHostedUpdateChecker(
            sourceStore: SelfUpdateSourceStore(storeURL: temporaryURL()),
            googleSearcher: StubSelfUpdateSearcher(result: nil),
            fetchData: { _ in Data() }
        )

        let apps = try checker.checkUpdates(for: [makeManualApp()])

        XCTAssertEqual(apps.first?.updateStatus, .needsManualUpdateURL)
    }

    func testUsesSavedUpdateURLToDetectLatestVersion() throws {
        let store = SelfUpdateSourceStore(storeURL: temporaryURL())
        try store.save(SelfUpdateSourceRecord(app: makeManualApp(), updateURL: URL(string: "https://example.com/download")!))
        let checker = SelfHostedUpdateChecker(
            sourceStore: store,
            googleSearcher: StubSelfUpdateSearcher(result: nil),
            detectors: [
                GenericWebPageUpdateDetector(fetchData: { _ in Data("Download version 2.4.0".utf8) }),
            ],
            fetchData: { _ in Data("Download version 2.4.0".utf8) }
        )

        let apps = try checker.checkUpdates(for: [makeManualApp(shortVersion: "2.3.0")])

        XCTAssertEqual(
            apps.first?.updateStatus,
            .updateAvailable(installedVersion: "2.3.0", latestVersion: "2.4.0")
        )
        XCTAssertEqual(apps.first?.updateURL, URL(string: "https://example.com/download"))
        XCTAssertEqual(apps.first?.updateURLIsDirectDownload, false)
    }

    func testUsesLatestPackageURLFromSavedUpdatePageWhenAvailable() throws {
        let store = SelfUpdateSourceStore(storeURL: temporaryURL())
        try store.save(SelfUpdateSourceRecord(app: makeManualApp(), updateURL: URL(string: "https://example.com/download")!))
        let checker = SelfHostedUpdateChecker(
            sourceStore: store,
            googleSearcher: StubSelfUpdateSearcher(result: nil),
            detectors: [
                GenericWebPageUpdateDetector(fetchData: { _ in Data("""
                <h1>Manual</h1>
                <p>Download version 2.4.0</p>
                <a href="/downloads/Manual-2.4.0.dmg">Download for macOS</a>
                """.utf8) }),
            ],
            fetchData: { _ in Data("""
            <h1>Manual</h1>
            <p>Download version 2.4.0</p>
            <a href="/downloads/Manual-2.4.0.dmg">Download for macOS</a>
            """.utf8) }
        )

        let apps = try checker.checkUpdates(for: [makeManualApp(shortVersion: "2.3.0")])

        XCTAssertEqual(
            apps.first?.updateStatus,
            .updateAvailable(installedVersion: "2.3.0", latestVersion: "2.4.0")
        )
        XCTAssertEqual(apps.first?.updateURL, URL(string: "https://example.com/downloads/Manual-2.4.0.dmg"))
        XCTAssertEqual(apps.first?.updateURLIsDirectDownload, true)
    }

    func testUsesGitHubDetectorForSavedProjectURL() throws {
        let store = SelfUpdateSourceStore(storeURL: temporaryURL())
        try store.save(SelfUpdateSourceRecord(
            app: makeManualApp(bundleIdentifier: "2dust.v2rayN", name: "v2rayN"),
            updateURL: URL(string: "https://github.com/2dust/v2rayN/releases")!
        ))
        let checker = SelfHostedUpdateChecker(
            sourceStore: store,
            googleSearcher: StubSelfUpdateSearcher(result: nil),
            recipeStore: StubUpdateRecipeStore(recipes: []),
            detectors: [
                GitHubReleaseUpdateDetector(targetArchitecture: .appleSilicon) { url in
                    XCTAssertEqual(url, URL(string: "https://api.github.com/repos/2dust/v2rayN/releases/latest")!)
                    return Data("""
                    {
                      "tag_name": "v7.22.7",
                      "assets": [
                        { "browser_download_url": "https://github.com/2dust/v2rayN/releases/download/7.22.7/v2rayN-macos-64.dmg" },
                        { "browser_download_url": "https://github.com/2dust/v2rayN/releases/download/7.22.7/v2rayN-macos-arm64.dmg" }
                      ]
                    }
                    """.utf8)
                },
            ],
            fetchData: { url in
                XCTFail("Injected GitHub detector should use its own fetcher, got \(url)")
                return Data()
            }
        )

        let apps = try checker.checkUpdates(for: [
            makeManualApp(bundleIdentifier: "2dust.v2rayN", name: "v2rayN", shortVersion: "7.20.4"),
        ])

        XCTAssertEqual(
            apps.first?.updateStatus,
            .updateAvailable(installedVersion: "7.20.4", latestVersion: "7.22.7")
        )
        XCTAssertEqual(
            apps.first?.updateURL,
            URL(string: "https://github.com/2dust/v2rayN/releases/download/7.22.7/v2rayN-macos-arm64.dmg")
        )
        XCTAssertEqual(apps.first?.updateURLIsDirectDownload, true)
    }

    func testGitHubDetectorPrefersIntelPackageForIntelArchitecture() throws {
        let store = SelfUpdateSourceStore(storeURL: temporaryURL())
        try store.save(SelfUpdateSourceRecord(
            app: makeManualApp(bundleIdentifier: "2dust.v2rayN", name: "v2rayN"),
            updateURL: URL(string: "https://github.com/2dust/v2rayN/releases")!
        ))
        let checker = SelfHostedUpdateChecker(
            sourceStore: store,
            googleSearcher: StubSelfUpdateSearcher(result: nil),
            recipeStore: StubUpdateRecipeStore(recipes: []),
            detectors: [
                GitHubReleaseUpdateDetector(targetArchitecture: .intel) { _ in
                    Data("""
                    {
                      "tag_name": "v7.22.7",
                      "assets": [
                        { "browser_download_url": "https://github.com/2dust/v2rayN/releases/download/7.22.7/v2rayN-macos-arm64.dmg" },
                        { "browser_download_url": "https://github.com/2dust/v2rayN/releases/download/7.22.7/v2rayN-macos-64.dmg" }
                      ]
                    }
                    """.utf8)
                },
            ],
            fetchData: { _ in Data() }
        )

        let apps = try checker.checkUpdates(for: [
            makeManualApp(bundleIdentifier: "2dust.v2rayN", name: "v2rayN", shortVersion: "7.20.4"),
        ])

        XCTAssertEqual(
            apps.first?.updateURL,
            URL(string: "https://github.com/2dust/v2rayN/releases/download/7.22.7/v2rayN-macos-64.dmg")
        )
    }

    func testUsesSparkleDetectorForSavedAppcastURL() throws {
        let store = SelfUpdateSourceStore(storeURL: temporaryURL())
        try store.save(SelfUpdateSourceRecord(app: makeManualApp(), updateURL: URL(string: "https://example.com/appcast.xml")!))
        let checker = SelfHostedUpdateChecker(
            sourceStore: store,
            googleSearcher: StubSelfUpdateSearcher(result: nil),
            recipeStore: StubUpdateRecipeStore(recipes: []),
            fetchData: { _ in Data("""
            <?xml version="1.0" encoding="utf-8"?>
            <rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
              <channel>
                <item>
                  <enclosure sparkle:shortVersionString="2.0.0" url="https://example.com/Manual-2.0.0.zip" />
                </item>
                <item>
                  <enclosure sparkle:shortVersionString="2.5.0" url="https://example.com/Manual-2.5.0.zip" />
                </item>
              </channel>
            </rss>
            """.utf8) }
        )

        let apps = try checker.checkUpdates(for: [makeManualApp(shortVersion: "2.0.0")])

        XCTAssertEqual(
            apps.first?.updateStatus,
            .updateAvailable(installedVersion: "2.0.0", latestVersion: "2.5.0")
        )
        XCTAssertEqual(apps.first?.updateURL, URL(string: "https://example.com/Manual-2.5.0.zip"))
        XCTAssertEqual(apps.first?.updateURLIsDirectDownload, true)
    }

    func testUsesJSONDetectorForSavedAPIURL() throws {
        let store = SelfUpdateSourceStore(storeURL: temporaryURL())
        try store.save(SelfUpdateSourceRecord(app: makeManualApp(), updateURL: URL(string: "https://example.com/api/latest")!))
        let checker = SelfHostedUpdateChecker(
            sourceStore: store,
            googleSearcher: StubSelfUpdateSearcher(result: nil),
            recipeStore: StubUpdateRecipeStore(recipes: []),
            fetchData: { _ in Data("""
            {
              "latestVersion": "3.1.0",
              "downloadUrl": "https://cdn.example.com/Manual-3.1.0.dmg"
            }
            """.utf8) }
        )

        let apps = try checker.checkUpdates(for: [makeManualApp(shortVersion: "3.0.0")])

        XCTAssertEqual(
            apps.first?.updateStatus,
            .updateAvailable(installedVersion: "3.0.0", latestVersion: "3.1.0")
        )
        XCTAssertEqual(apps.first?.updateURL, URL(string: "https://cdn.example.com/Manual-3.1.0.dmg"))
        XCTAssertEqual(apps.first?.updateURLIsDirectDownload, true)
    }

    func testUsesRedirectDetectorForVersionedFinalPackageURL() throws {
        let updateURL = URL(string: "https://example.com/download/latest")!
        let finalURL = URL(string: "https://cdn.example.com/Manual-4.2.0.pkg")!
        let store = SelfUpdateSourceStore(storeURL: temporaryURL())
        try store.save(SelfUpdateSourceRecord(app: makeManualApp(), updateURL: updateURL))
        let checker = SelfHostedUpdateChecker(
            sourceStore: store,
            googleSearcher: StubSelfUpdateSearcher(result: nil),
            recipeStore: StubUpdateRecipeStore(recipes: []),
            detectors: [
                RedirectDownloadUpdateDetector { url in
                    XCTAssertEqual(url, updateURL)
                    return finalURL
                },
            ],
            fetchData: { _ in
                XCTFail("Redirect detector should not fetch page data")
                return Data()
            }
        )

        let apps = try checker.checkUpdates(for: [makeManualApp(shortVersion: "4.1.0")])

        XCTAssertEqual(
            apps.first?.updateStatus,
            .updateAvailable(installedVersion: "4.1.0", latestVersion: "4.2.0")
        )
        XCTAssertEqual(apps.first?.updateURL, finalURL)
        XCTAssertEqual(apps.first?.updateURLIsDirectDownload, true)
    }

    func testUsesInjectedDetectorBeforeGenericFallback() throws {
        let store = SelfUpdateSourceStore(storeURL: temporaryURL())
        try store.save(SelfUpdateSourceRecord(app: makeManualApp(), updateURL: URL(string: "https://example.com/download")!))
        let checker = SelfHostedUpdateChecker(
            sourceStore: store,
            googleSearcher: StubSelfUpdateSearcher(result: nil),
            recipeStore: StubUpdateRecipeStore(recipes: []),
            detectors: [
                StubSelfHostedUpdateDetector(release: SelfHostedRelease(
                    latestVersion: "3.0.0",
                    packageURL: URL(string: "https://cdn.example.com/Manual-3.0.0.dmg")!
                )),
            ],
            fetchData: { _ in
                XCTFail("Injected detector should avoid generic webpage fetching")
                return Data()
            }
        )

        let apps = try checker.checkUpdates(for: [makeManualApp(shortVersion: "2.0.0")])

        XCTAssertEqual(
            apps.first?.updateStatus,
            .updateAvailable(installedVersion: "2.0.0", latestVersion: "3.0.0")
        )
        XCTAssertEqual(apps.first?.updateURL, URL(string: "https://cdn.example.com/Manual-3.0.0.dmg"))
        XCTAssertEqual(apps.first?.updateURLIsDirectDownload, true)
    }

    func testUsesRecipeToDetectLatestVersionWithoutSearching() throws {
        let recipe = UpdateRecipe(
            id: "net.freemacsoft.AppCleaner",
            name: "AppCleaner",
            recipePrompt: "Use the official AppCleaner downloads section on freemacsoft.net.",
            match: UpdateRecipe.Match(
                bundleIdentifier: "net.freemacsoft.AppCleaner",
                appName: nil,
                officialHost: "freemacsoft.net"
            ),
            checks: [
                UpdateRecipe.Check(
                    url: URL(string: "https://freemacsoft.net/appcleaner/")!,
                    extract: UpdateRecipe.Extract(
                        type: .regex,
                        pattern: #"Version\s+([0-9]+(?:\.[0-9A-Za-z]+){1,5})"#,
                        versionGroup: 1
                    )
                ),
            ],
            updatePageURL: URL(string: "https://freemacsoft.net/appcleaner/")!,
            download: UpdateRecipe.Download(
                url: nil,
                sourceURL: URL(string: "https://freemacsoft.net/appcleaner/")!,
                pattern: #"href="([^"]*AppCleaner_3\.6\.8\.zip)""#,
                urlGroup: 1
            )
        )
        let checker = SelfHostedUpdateChecker(
            sourceStore: SelfUpdateSourceStore(storeURL: temporaryURL()),
            googleSearcher: FailingSelfUpdateSearcher(),
            recipeStore: StubUpdateRecipeStore(recipes: [recipe]),
            fetchData: { url in
                XCTAssertEqual(url, URL(string: "https://freemacsoft.net/appcleaner/")!)
                return Data("""
                <h3>Downloads</h3>
                <strong>Version 3.6.8</strong>
                <a href="/appcleaner/AppCleaner_3.6.8.zip">Download</a>
                <strong>Version 3.6</strong>
                """.utf8)
            }
        )

        let apps = try checker.checkUpdates(for: [makeAppCleaner(shortVersion: "3.6")])

        XCTAssertEqual(
            apps.first?.updateStatus,
            .updateAvailable(installedVersion: "3.6", latestVersion: "3.6.8")
        )
        XCTAssertEqual(apps.first?.updateURL, URL(string: "https://freemacsoft.net/appcleaner/AppCleaner_3.6.8.zip"))
        XCTAssertEqual(apps.first?.updateURLIsDirectDownload, true)
    }

    func testExplicitRecipeDownloadPrefersPackageMatchingLatestVersion() throws {
        let recipe = UpdateRecipe(
            id: "com.example.manual",
            name: "Manual",
            recipePrompt: "Prefer the package URL matching the latest detected version.",
            match: UpdateRecipe.Match(
                bundleIdentifier: "com.example.manual",
                appName: "Manual",
                officialHost: "example.com"
            ),
            checks: [
                UpdateRecipe.Check(
                    url: URL(string: "https://example.com/appcast.xml")!,
                    extract: UpdateRecipe.Extract(
                        type: .regex,
                        pattern: #"sparkle:version="([0-9]+(?:\.[0-9A-Za-z]+){1,5})""#,
                        versionGroup: 1
                    )
                ),
            ],
            updatePageURL: URL(string: "https://example.com/download")!,
            download: UpdateRecipe.Download(
                url: nil,
                sourceURL: URL(string: "https://example.com/appcast.xml")!,
                pattern: #"url="([^"]*Manual-[^"]+\.zip)""#,
                urlGroup: 1
            )
        )
        let checker = SelfHostedUpdateChecker(
            sourceStore: SelfUpdateSourceStore(storeURL: temporaryURL()),
            googleSearcher: FailingSelfUpdateSearcher(),
            recipeStore: StubUpdateRecipeStore(recipes: [recipe]),
            fetchData: { _ in Data("""
            <enclosure url="https://example.com/Manual-1_0_0.zip" sparkle:version="1.0.0" />
            <enclosure url="https://example.com/Manual-2_0_0.zip" sparkle:version="2.0.0" />
            """.utf8) }
        )

        let apps = try checker.checkUpdates(for: [makeManualApp(shortVersion: "1.0.0")])

        XCTAssertEqual(
            apps.first?.updateStatus,
            .updateAvailable(installedVersion: "1.0.0", latestVersion: "2.0.0")
        )
        XCTAssertEqual(apps.first?.updateURL, URL(string: "https://example.com/Manual-2_0_0.zip"))
        XCTAssertEqual(apps.first?.updateURLIsDirectDownload, true)
    }

    func testExplicitRecipeDownloadPrefersCurrentCPUArchitecturePackage() throws {
        let recipe = UpdateRecipe(
            id: "com.example.arch",
            name: "ArchApp",
            recipePrompt: "Prefer the package matching the current CPU architecture.",
            match: UpdateRecipe.Match(
                bundleIdentifier: "com.example.arch",
                appName: "ArchApp",
                officialHost: "example.com"
            ),
            checks: [
                UpdateRecipe.Check(
                    url: URL(string: "https://example.com/releases/latest")!,
                    extract: UpdateRecipe.Extract(
                        type: .regex,
                        pattern: #"tag_name"\s*:\s*"v?([0-9]+(?:\.[0-9A-Za-z]+){1,5})""#,
                        versionGroup: 1
                    )
                ),
            ],
            updatePageURL: URL(string: "https://example.com/releases")!,
            download: UpdateRecipe.Download(
                url: nil,
                sourceURL: URL(string: "https://example.com/releases/latest")!,
                pattern: #"browser_download_url"\s*:\s*"([^"]*macos[^"]*\.dmg)""#,
                urlGroup: 1
            )
        )
        let checker = SelfHostedUpdateChecker(
            sourceStore: SelfUpdateSourceStore(storeURL: temporaryURL()),
            googleSearcher: FailingSelfUpdateSearcher(),
            recipeStore: StubUpdateRecipeStore(recipes: [recipe]),
            fetchData: { _ in Data("""
            {
              "tag_name": "v2.0.0",
              "assets": [
                { "browser_download_url": "https://example.com/ArchApp-2.0.0-macos-amd64.dmg" },
                { "browser_download_url": "https://example.com/ArchApp-2.0.0-macos-arm64.dmg" }
              ]
            }
            """.utf8) }
        )

        let apps = try checker.checkUpdates(for: [
            makeManualApp(bundleIdentifier: "com.example.arch", name: "ArchApp", shortVersion: "1.0.0"),
        ])

        switch PackageTargetArchitecture.current {
        case .appleSilicon:
            XCTAssertEqual(apps.first?.updateURL, URL(string: "https://example.com/ArchApp-2.0.0-macos-arm64.dmg"))
        case .intel:
            XCTAssertEqual(apps.first?.updateURL, URL(string: "https://example.com/ArchApp-2.0.0-macos-amd64.dmg"))
        }
        XCTAssertEqual(apps.first?.updateURLIsDirectDownload, true)
    }

    func testBundledTypelessRecipeDetectsMacArmPackageURL() throws {
        let recipes = try FileUpdateRecipeStore(
            builtInDirectoryURLs: [
                URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
                    .appendingPathComponent("Resources/UpdateRecipes", isDirectory: true),
            ],
            userDirectoryURL: temporaryRecipeDirectory()
        ).load()
        let recipe = try XCTUnwrap(recipes.first { $0.id == "now.typeless.desktop" })
        let checker = SelfHostedUpdateChecker(
            sourceStore: SelfUpdateSourceStore(storeURL: temporaryURL()),
            googleSearcher: FailingSelfUpdateSearcher(),
            recipeStore: StubUpdateRecipeStore(recipes: [recipe]),
            fetchData: { url in
                XCTAssertEqual(url, URL(string: "https://typeless-static.com/desktop-release/arm64-mac.yml")!)
                return Data("""
                version: 1.8.0
                files:
                  - url: Typeless-1.8.0-arm64.zip
                    size: 163308866
                  - url: Typeless-1.8.0-arm64.dmg
                    size: 171020970
                path: Typeless-1.8.0-arm64.zip
                """.utf8)
            }
        )

        let apps = try checker.checkUpdates(for: [
            makeManualApp(bundleIdentifier: "now.typeless.desktop", name: "Typeless", shortVersion: "1.7.0"),
        ])

        XCTAssertEqual(
            apps.first?.updateStatus,
            .updateAvailable(installedVersion: "1.7.0", latestVersion: "1.8.0")
        )
        XCTAssertEqual(
            apps.first?.updateURL,
            URL(string: "https://typeless-static.com/desktop-release/Typeless-1.8.0-arm64.dmg")
        )
        XCTAssertEqual(apps.first?.updateURLIsDirectDownload, true)
    }

    func testBundledFlClashRecipePrefersMacArmPackageURL() throws {
        let recipes = try FileUpdateRecipeStore(
            builtInDirectoryURLs: [
                URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
                    .appendingPathComponent("Resources/UpdateRecipes", isDirectory: true),
            ],
            userDirectoryURL: temporaryRecipeDirectory()
        ).load()
        let recipe = try XCTUnwrap(recipes.first { $0.id == "com.follow.clash" })
        let checker = SelfHostedUpdateChecker(
            sourceStore: SelfUpdateSourceStore(storeURL: temporaryURL()),
            googleSearcher: FailingSelfUpdateSearcher(),
            recipeStore: StubUpdateRecipeStore(recipes: [recipe]),
            fetchData: { url in
                XCTAssertEqual(url, URL(string: "https://api.github.com/repos/chen08209/FlClash/releases/latest")!)
                return Data("""
                {
                  "tag_name": "v0.8.93",
                  "assets": [
                    { "browser_download_url": "https://github.com/chen08209/FlClash/releases/download/v0.8.93/FlClash-0.8.93-macos-amd64.dmg" },
                    { "browser_download_url": "https://github.com/chen08209/FlClash/releases/download/v0.8.93/FlClash-0.8.93-macos-arm64.dmg" }
                  ]
                }
                """.utf8)
            }
        )

        let apps = try checker.checkUpdates(for: [
            makeManualApp(bundleIdentifier: "com.follow.clash", name: "FlClash", shortVersion: "0.8.92"),
        ])

        XCTAssertEqual(
            apps.first?.updateURL,
            URL(string: "https://github.com/chen08209/FlClash/releases/download/v0.8.93/FlClash-0.8.93-macos-arm64.dmg")
        )
        XCTAssertEqual(apps.first?.updateURLIsDirectDownload, true)
    }

    func testBundledSniffnetRecipeDetectsAppleSiliconPackageURL() throws {
        let recipes = try FileUpdateRecipeStore(
            builtInDirectoryURLs: [
                URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
                    .appendingPathComponent("Resources/UpdateRecipes", isDirectory: true),
            ],
            userDirectoryURL: temporaryRecipeDirectory()
        ).load()
        let recipe = try XCTUnwrap(recipes.first { $0.id == "io.github.gyulyvgc.sniffnet" })
        let checker = SelfHostedUpdateChecker(
            sourceStore: SelfUpdateSourceStore(storeURL: temporaryURL()),
            googleSearcher: FailingSelfUpdateSearcher(),
            recipeStore: StubUpdateRecipeStore(recipes: [recipe]),
            fetchData: { url in
                XCTAssertEqual(url, URL(string: "https://api.github.com/repos/gyulyvgc/sniffnet/releases/latest")!)
                return Data("""
                {
                  "tag_name": "v1.5.0",
                  "assets": [
                    { "browser_download_url": "https://github.com/gyulyvgc/sniffnet/releases/download/v1.5.0/Sniffnet_macOS_Intel.dmg" },
                    { "browser_download_url": "https://github.com/gyulyvgc/sniffnet/releases/download/v1.5.0/Sniffnet_macOS_AppleSilicon.dmg" }
                  ]
                }
                """.utf8)
            }
        )

        let apps = try checker.checkUpdates(for: [
            makeManualApp(bundleIdentifier: "io.github.gyulyvgc.sniffnet", name: "Sniffnet", shortVersion: "1.4.0"),
        ])

        XCTAssertEqual(
            apps.first?.updateURL,
            URL(string: "https://github.com/gyulyvgc/sniffnet/releases/download/v1.5.0/Sniffnet_macOS_AppleSilicon.dmg")
        )
        XCTAssertEqual(apps.first?.updateURLIsDirectDownload, true)
    }

    func testBundledV2rayNRecipePrefersMacArmPackageURL() throws {
        let recipes = try FileUpdateRecipeStore(
            builtInDirectoryURLs: [
                URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
                    .appendingPathComponent("Resources/UpdateRecipes", isDirectory: true),
            ],
            userDirectoryURL: temporaryRecipeDirectory()
        ).load()
        let recipe = try XCTUnwrap(recipes.first { $0.id == "2dust.v2rayN" })
        let checker = SelfHostedUpdateChecker(
            sourceStore: SelfUpdateSourceStore(storeURL: temporaryURL()),
            googleSearcher: FailingSelfUpdateSearcher(),
            recipeStore: StubUpdateRecipeStore(recipes: [recipe]),
            fetchData: { url in
                XCTAssertEqual(url, URL(string: "https://api.github.com/repos/2dust/v2rayN/releases/latest")!)
                return Data("""
                {
                  "tag_name": "7.22.7",
                  "assets": [
                    { "browser_download_url": "https://github.com/2dust/v2rayN/releases/download/7.22.7/v2rayN-macos-64.dmg" },
                    { "browser_download_url": "https://github.com/2dust/v2rayN/releases/download/7.22.7/v2rayN-macos-arm64.dmg" }
                  ]
                }
                """.utf8)
            }
        )

        let apps = try checker.checkUpdates(for: [
            makeManualApp(bundleIdentifier: "2dust.v2rayN", name: "v2rayN", shortVersion: "7.20.4"),
        ])

        XCTAssertEqual(
            apps.first?.updateURL,
            URL(string: "https://github.com/2dust/v2rayN/releases/download/7.22.7/v2rayN-macos-arm64.dmg")
        )
        XCTAssertEqual(apps.first?.updateURLIsDirectDownload, true)
    }

    func testEmptyRecipeFallsBackToManualInputWithoutSearching() throws {
        let recipe = UpdateRecipe(
            id: "com.example.manual",
            name: "Manual",
            recipePrompt: "This app is known, but it has no stable public version endpoint.",
            match: UpdateRecipe.Match(
                bundleIdentifier: "com.example.manual",
                appName: "Manual",
                officialHost: nil
            ),
            checks: [],
            updatePageURL: URL(string: "https://example.com/download")!
        )
        let checker = SelfHostedUpdateChecker(
            sourceStore: SelfUpdateSourceStore(storeURL: temporaryURL()),
            googleSearcher: FailingSelfUpdateSearcher(),
            recipeStore: StubUpdateRecipeStore(recipes: [recipe]),
            fetchData: { _ in
                XCTFail("Empty recipes should not fetch version pages")
                return Data()
            }
        )

        let apps = try checker.checkUpdates(for: [makeManualApp()])

        XCTAssertEqual(apps.first?.updateStatus, .needsManualUpdateURL)
        XCTAssertEqual(apps.first?.updateURL, URL(string: "https://example.com/download"))
    }

    func testMarksSavedUpdateURLAsUndetectableWhenPageHasNoVersion() throws {
        let store = SelfUpdateSourceStore(storeURL: temporaryURL())
        try store.save(SelfUpdateSourceRecord(app: makeManualApp(), updateURL: URL(string: "https://example.com/download")!))
        let checker = SelfHostedUpdateChecker(
            sourceStore: store,
            googleSearcher: StubSelfUpdateSearcher(result: nil),
            detectors: [
                GenericWebPageUpdateDetector(fetchData: { _ in Data("Download the latest build".utf8) }),
            ],
            fetchData: { _ in Data("Download the latest build".utf8) }
        )

        let apps = try checker.checkUpdates(for: [makeManualApp()])

        XCTAssertEqual(apps.first?.updateStatus, .undetectable)
    }

    func testTinyFishSearcherReturnsFirstAllowedCandidate() throws {
        let searcher = TinyFishSelfUpdateSearcher(apiKey: "sk-test") { url, headers in
            XCTAssertEqual(url.host, "api.search.tinyfish.ai")
            XCTAssertEqual(headers["X-API-Key"], "sk-test")
            XCTAssertTrue(url.absoluteString.contains("query=Manual"))
            return Data("""
            {
              "results": [
                {
                  "title": "Manual for Mac - Download",
                  "url": "https://manual.macupdate.com/"
                },
                {
                  "title": "Manual Official",
                  "url": "https://example.com/download?ref=search#top"
                }
              ]
            }
            """.utf8)
        }

        let url = try searcher.searchOfficialWebsite(for: makeManualApp())

        XCTAssertEqual(url, URL(string: "https://example.com/download"))
    }

    private func makeManualApp(
        bundleIdentifier: String = "com.example.manual",
        name: String = "Manual",
        shortVersion: String = "1.0"
    ) -> AppRecord {
        AppRecord(
            id: bundleIdentifier,
            name: name,
            bundleIdentifier: bundleIdentifier,
            shortVersion: shortVersion,
            buildVersion: nil,
            path: URL(fileURLWithPath: "/Applications/\(name).app"),
            sizeBytes: 1,
            installSource: .manual(reason: "unknown")
        )
    }

    private func makeAppCleaner(shortVersion: String) -> AppRecord {
        AppRecord(
            id: "net.freemacsoft.AppCleaner",
            name: "AppCleaner",
            bundleIdentifier: "net.freemacsoft.AppCleaner",
            shortVersion: shortVersion,
            buildVersion: nil,
            path: URL(fileURLWithPath: "/Applications/AppCleaner.app"),
            sizeBytes: 1,
            installSource: .manual(reason: "unknown")
        )
    }

    private func temporaryURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("json")
    }

    private func temporaryRecipeDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
    }
}

private struct StubSelfUpdateSearcher: SelfUpdateSearching {
    let result: URL?

    func searchOfficialWebsite(for app: AppRecord) throws -> URL? {
        result
    }
}

private struct FailingSelfUpdateSearcher: SelfUpdateSearching {
    func searchOfficialWebsite(for app: AppRecord) throws -> URL? {
        XCTFail("Recipe-backed checks should not search for a website first")
        return nil
    }
}

private struct StubUpdateRecipeStore: UpdateRecipeStoring {
    let recipes: [UpdateRecipe]

    func load() throws -> [UpdateRecipe] {
        recipes
    }
}

private struct StubSelfHostedUpdateDetector: SelfHostedUpdateDetecting {
    let release: SelfHostedRelease?

    func detectRelease(for app: AppRecord, updateURL: URL) throws -> SelfHostedRelease? {
        release
    }
}
