import XCTest
@testable import AppManCore

final class HomebrewCaskDetectorTests: XCTestCase {
    func testDetectsAppByAppArtifactNameFromBrewInfoJSON() throws {
        let runner = StubCommandRunner(
            installedCasksOutput: "visual-studio-code 1.0\n",
            infoOutput: """
            {
              "casks": [
                {
                  "token": "visual-studio-code",
                  "artifacts": [
                    {
                      "app": [
                        "Visual Studio Code.app"
                      ]
                    }
                  ]
                }
              ]
            }
            """
        )
        let detector = HomebrewCaskDetector(commandRunner: runner)
        let app = makeAppRecord(path: URL(fileURLWithPath: "/Applications/Visual Studio Code.app"))

        let source = try detector.detectInstallSource(for: app)

        XCTAssertEqual(source, .homebrewCask(token: "visual-studio-code"))
    }

    func testReturnsNilWhenBrewIsUnavailable() throws {
        let runner = StubCommandRunner(listError: CommandError.executableNotFound("brew"))
        let detector = HomebrewCaskDetector(commandRunner: runner)
        let app = makeAppRecord(path: URL(fileURLWithPath: "/Applications/Visual Studio Code.app"))

        let source = try detector.detectInstallSource(for: app)

        XCTAssertNil(source)
    }

    func testIgnoresNonAppArtifactsWhenMatching() throws {
        let runner = StubCommandRunner(
            installedCasksOutput: "visual-studio-code 1.0\n",
            infoOutput: """
            {
              "casks": [
                {
                  "token": "visual-studio-code",
                  "artifacts": [
                    {
                      "binary": [
                        "code"
                      ]
                    },
                    {
                      "app": [
                        "Visual Studio Code.app"
                      ]
                    }
                  ]
                }
              ]
            }
            """
        )
        let detector = HomebrewCaskDetector(commandRunner: runner)
        let app = makeAppRecord(path: URL(fileURLWithPath: "/Applications/Visual Studio Code.app"))

        let source = try detector.detectInstallSource(for: app)

        XCTAssertEqual(source, .homebrewCask(token: "visual-studio-code"))
    }

    func testExtractsStringAppNameFromMixedAppArtifactElements() throws {
        let runner = StubCommandRunner(
            installedCasksOutput: "visual-studio-code 1.0\n",
            infoOutput: """
            {
              "casks": [
                {
                  "token": "visual-studio-code",
                  "artifacts": [
                    {
                      "app": [
                        {
                          "target": "Ignored.app"
                        },
                        42,
                        "Visual Studio Code.app"
                      ]
                    }
                  ]
                }
              ]
            }
            """
        )
        let detector = HomebrewCaskDetector(commandRunner: runner)
        let app = makeAppRecord(path: URL(fileURLWithPath: "/Applications/Visual Studio Code.app"))

        let source = try detector.detectInstallSource(for: app)

        XCTAssertEqual(source, .homebrewCask(token: "visual-studio-code"))
    }

    func testReturnsNilForEmptyOutput() throws {
        let runner = StubCommandRunner(installedCasksOutput: "visual-studio-code 1.0\n", infoOutput: "")
        let detector = HomebrewCaskDetector(commandRunner: runner)
        let app = makeAppRecord(path: URL(fileURLWithPath: "/Applications/Visual Studio Code.app"))

        let source = try detector.detectInstallSource(for: app)

        XCTAssertNil(source)
    }

    func testReturnsNilForEmptyCasks() throws {
        let runner = StubCommandRunner(
            installedCasksOutput: "visual-studio-code 1.0\n",
            infoOutput: """
            {
              "casks": []
            }
            """
        )
        let detector = HomebrewCaskDetector(commandRunner: runner)
        let app = makeAppRecord(path: URL(fileURLWithPath: "/Applications/Visual Studio Code.app"))

        let source = try detector.detectInstallSource(for: app)

        XCTAssertNil(source)
    }

    func testReturnsMatchingTokenFromMultipleCasks() throws {
        let runner = StubCommandRunner(
            installedCasksOutput: "firefox 1.0\nvisual-studio-code 1.0\n",
            infoOutput: """
            {
              "casks": [
                {
                  "token": "firefox",
                  "artifacts": [
                    {
                      "app": [
                        "Firefox.app"
                      ]
                    }
                  ]
                },
                {
                  "token": "visual-studio-code",
                  "artifacts": [
                    {
                      "app": [
                        "Visual Studio Code.app"
                      ]
                    }
                  ]
                }
              ]
            }
            """
        )
        let detector = HomebrewCaskDetector(commandRunner: runner)
        let app = makeAppRecord(path: URL(fileURLWithPath: "/Applications/Visual Studio Code.app"))

        let source = try detector.detectInstallSource(for: app)

        XCTAssertEqual(source, .homebrewCask(token: "visual-studio-code"))
    }

    func testReturnsFirstTokenWhenMultipleCasksDeclareSameAppName() throws {
        let runner = StubCommandRunner(
            installedCasksOutput: "first-shared 1.0\nsecond-shared 1.0\n",
            infoOutput: """
            {
              "casks": [
                {
                  "token": "first-shared",
                  "artifacts": [
                    {
                      "app": [
                        "Shared.app"
                      ]
                    }
                  ]
                },
                {
                  "token": "second-shared",
                  "artifacts": [
                    {
                      "app": [
                        "Shared.app"
                      ]
                    }
                  ]
                }
              ]
            }
            """
        )
        let detector = HomebrewCaskDetector(commandRunner: runner)
        let app = makeAppRecord(path: URL(fileURLWithPath: "/Applications/Shared.app"))

        let source = try detector.detectInstallSource(for: app)

        XCTAssertEqual(source, .homebrewCask(token: "first-shared"))
    }

    func testCachesBrewInfoForMultipleDetectionsOnSameDetector() throws {
        let runner = CountingCommandRunner(infoOutput: """
        {
          "casks": [
            {
              "token": "firefox",
              "artifacts": [
                {
                  "app": [
                    "Firefox.app"
                  ]
                }
              ]
            }
          ]
        }
        """)
        let detector = HomebrewCaskDetector(commandRunner: runner)
        let firefox = makeAppRecord(path: URL(fileURLWithPath: "/Applications/Firefox.app"))
        let safari = makeAppRecord(path: URL(fileURLWithPath: "/Applications/Safari.app"))

        let firefoxSource = try detector.detectInstallSource(for: firefox)
        let safariSource = try detector.detectInstallSource(for: safari)

        XCTAssertEqual(firefoxSource, .homebrewCask(token: "firefox"))
        XCTAssertNil(safariSource)
        XCTAssertEqual(runner.runCallCount, 2)
    }

    func testReturnsNilWhenNoCasksAreInstalled() throws {
        let runner = StubCommandRunner(installedCasksOutput: "")
        let detector = HomebrewCaskDetector(commandRunner: runner)
        let app = makeAppRecord(path: URL(fileURLWithPath: "/Applications/Visual Studio Code.app"))

        let source = try detector.detectInstallSource(for: app)

        XCTAssertNil(source)
    }

    func testOnlyQueriesInstalledCaskTokens() throws {
        let runner = RecordingCommandRunner(
            installedCasksOutput: "visual-studio-code 1.0\n",
            infoOutput: """
            {
              "casks": [
                {
                  "token": "visual-studio-code",
                  "artifacts": [
                    {
                      "app": [
                        "Visual Studio Code.app"
                      ]
                    }
                  ]
                }
              ]
            }
            """
        )
        let detector = HomebrewCaskDetector(commandRunner: runner)
        let app = makeAppRecord(path: URL(fileURLWithPath: "/Applications/Visual Studio Code.app"))

        _ = try detector.detectInstallSource(for: app)

        XCTAssertEqual(runner.commands, [
            ["brew", "list", "--cask", "--versions"],
            ["brew", "info", "--cask", "--json=v2", "visual-studio-code"],
        ])
    }

    func testProcessCommandRunnerDrainsLargeStdoutWhileProcessWritesStderr() throws {
        let runner = ProcessCommandRunner(searchDirectories: shellSearchDirectories)

        let output = try runner.run("sh", arguments: [
            "-c",
            """
            i=0
            while [ "$i" -lt 20000 ]; do
              printf 'PIPE_STDOUT_MARKER_%05d\\n' "$i"
              i=$((i + 1))
            done
            printf 'PIPE_STDERR_MARKER\\n' >&2
            """
        ])

        XCTAssertTrue(output.contains("PIPE_STDOUT_MARKER_00000"))
        XCTAssertTrue(output.contains("PIPE_STDOUT_MARKER_19999"))
    }

    func testProcessCommandRunnerCapturesStderrWhenCommandFails() throws {
        let runner = ProcessCommandRunner(searchDirectories: shellSearchDirectories)

        XCTAssertThrowsError(try runner.run("sh", arguments: [
            "-c",
            "printf 'PIPE_FAILURE_STDERR_MARKER\\n' >&2; exit 7"
        ])) { error in
            XCTAssertEqual(
                error as? CommandError,
                .failed(status: 7, stderr: "PIPE_FAILURE_STDERR_MARKER\n")
            )
        }
    }

    private func makeAppRecord(path: URL) -> AppRecord {
        AppRecord(
            id: "com.microsoft.VSCode",
            name: "Visual Studio Code",
            bundleIdentifier: "com.microsoft.VSCode",
            shortVersion: nil,
            buildVersion: nil,
            path: path,
            sizeBytes: 0
        )
    }

    private var shellSearchDirectories: [URL] {
        [
            URL(fileURLWithPath: "/bin", isDirectory: true),
            URL(fileURLWithPath: "/usr/bin", isDirectory: true),
        ]
    }
}

private struct StubCommandRunner: CommandRunning {
    private let installedCasksOutput: String
    private let infoOutput: String
    private let listError: CommandError?
    private let infoError: CommandError?

    init(
        installedCasksOutput: String = "",
        infoOutput: String = "",
        listError: CommandError? = nil,
        infoError: CommandError? = nil
    ) {
        self.installedCasksOutput = installedCasksOutput
        self.infoOutput = infoOutput
        self.listError = listError
        self.infoError = infoError
    }

    func run(_ executable: String, arguments: [String]) throws -> String {
        XCTAssertEqual(executable, "brew")
        switch arguments.prefix(3) {
        case ["list", "--cask", "--versions"]:
            if let listError {
                throw listError
            }
            return installedCasksOutput
        case ["info", "--cask", "--json=v2"]:
            if let infoError {
                throw infoError
            }
            return infoOutput
        default:
            XCTFail("Unexpected brew arguments: \(arguments)")
            return ""
        }
    }
}

private final class CountingCommandRunner: CommandRunning, @unchecked Sendable {
    private let infoOutput: String
    private(set) var runCallCount = 0

    init(infoOutput: String) {
        self.infoOutput = infoOutput
    }

    func run(_ executable: String, arguments: [String]) throws -> String {
        XCTAssertEqual(executable, "brew")
        runCallCount += 1
        if arguments == ["list", "--cask", "--versions"] {
            return "firefox 1.0\n"
        }
        XCTAssertEqual(arguments, ["info", "--cask", "--json=v2", "firefox"])
        return infoOutput
    }
}

private final class RecordingCommandRunner: CommandRunning, @unchecked Sendable {
    private let installedCasksOutput: String
    private let infoOutput: String
    private(set) var commands: [[String]] = []

    init(installedCasksOutput: String, infoOutput: String) {
        self.installedCasksOutput = installedCasksOutput
        self.infoOutput = infoOutput
    }

    func run(_ executable: String, arguments: [String]) throws -> String {
        commands.append([executable] + arguments)
        if arguments == ["list", "--cask", "--versions"] {
            return installedCasksOutput
        }
        return infoOutput
    }
}
