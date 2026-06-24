import XCTest
@testable import AppManCore

final class HomebrewCaskDetectorTests: XCTestCase {
    func testDetectsAppByAppArtifactNameFromBrewInfoJSON() throws {
        let runner = StubCommandRunner(output: """
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
        """)
        let detector = HomebrewCaskDetector(commandRunner: runner)
        let app = makeAppRecord(path: URL(fileURLWithPath: "/Applications/Visual Studio Code.app"))

        let source = try detector.detectInstallSource(for: app)

        XCTAssertEqual(source, .homebrewCask(token: "visual-studio-code"))
    }

    func testReturnsNilWhenBrewIsUnavailable() throws {
        let runner = StubCommandRunner(error: CommandError.executableNotFound("brew"))
        let detector = HomebrewCaskDetector(commandRunner: runner)
        let app = makeAppRecord(path: URL(fileURLWithPath: "/Applications/Visual Studio Code.app"))

        let source = try detector.detectInstallSource(for: app)

        XCTAssertNil(source)
    }

    func testIgnoresNonAppArtifactsWhenMatching() throws {
        let runner = StubCommandRunner(output: """
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
        """)
        let detector = HomebrewCaskDetector(commandRunner: runner)
        let app = makeAppRecord(path: URL(fileURLWithPath: "/Applications/Visual Studio Code.app"))

        let source = try detector.detectInstallSource(for: app)

        XCTAssertEqual(source, .homebrewCask(token: "visual-studio-code"))
    }

    func testExtractsStringAppNameFromMixedAppArtifactElements() throws {
        let runner = StubCommandRunner(output: """
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
        """)
        let detector = HomebrewCaskDetector(commandRunner: runner)
        let app = makeAppRecord(path: URL(fileURLWithPath: "/Applications/Visual Studio Code.app"))

        let source = try detector.detectInstallSource(for: app)

        XCTAssertEqual(source, .homebrewCask(token: "visual-studio-code"))
    }

    func testReturnsNilForEmptyOutput() throws {
        let runner = StubCommandRunner(output: "")
        let detector = HomebrewCaskDetector(commandRunner: runner)
        let app = makeAppRecord(path: URL(fileURLWithPath: "/Applications/Visual Studio Code.app"))

        let source = try detector.detectInstallSource(for: app)

        XCTAssertNil(source)
    }

    func testReturnsNilForEmptyCasks() throws {
        let runner = StubCommandRunner(output: """
        {
          "casks": []
        }
        """)
        let detector = HomebrewCaskDetector(commandRunner: runner)
        let app = makeAppRecord(path: URL(fileURLWithPath: "/Applications/Visual Studio Code.app"))

        let source = try detector.detectInstallSource(for: app)

        XCTAssertNil(source)
    }

    func testReturnsMatchingTokenFromMultipleCasks() throws {
        let runner = StubCommandRunner(output: """
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
        """)
        let detector = HomebrewCaskDetector(commandRunner: runner)
        let app = makeAppRecord(path: URL(fileURLWithPath: "/Applications/Visual Studio Code.app"))

        let source = try detector.detectInstallSource(for: app)

        XCTAssertEqual(source, .homebrewCask(token: "visual-studio-code"))
    }

    func testReturnsFirstTokenWhenMultipleCasksDeclareSameAppName() throws {
        let runner = StubCommandRunner(output: """
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
        """)
        let detector = HomebrewCaskDetector(commandRunner: runner)
        let app = makeAppRecord(path: URL(fileURLWithPath: "/Applications/Shared.app"))

        let source = try detector.detectInstallSource(for: app)

        XCTAssertEqual(source, .homebrewCask(token: "first-shared"))
    }

    func testCachesBrewInfoForMultipleDetectionsOnSameDetector() throws {
        let runner = CountingCommandRunner(output: """
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
        XCTAssertEqual(runner.runCallCount, 1)
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
    private let output: String
    private let error: CommandError?
    let expectedExecutable: String
    let expectedArguments: [String]

    init(
        output: String = "",
        error: CommandError? = nil,
        expectedExecutable: String = "brew",
        expectedArguments: [String] = ["info", "--cask", "--json=v2"]
    ) {
        self.output = output
        self.error = error
        self.expectedExecutable = expectedExecutable
        self.expectedArguments = expectedArguments
    }

    func run(_ executable: String, arguments: [String]) throws -> String {
        XCTAssertEqual(executable, expectedExecutable)
        XCTAssertEqual(arguments, expectedArguments)
        if let error {
            throw error
        }
        return output
    }
}

private final class CountingCommandRunner: CommandRunning, @unchecked Sendable {
    private let output: String
    private(set) var runCallCount = 0

    init(output: String) {
        self.output = output
    }

    func run(_ executable: String, arguments: [String]) throws -> String {
        XCTAssertEqual(executable, "brew")
        XCTAssertEqual(arguments, ["info", "--cask", "--json=v2"])
        runCallCount += 1
        return output
    }
}
