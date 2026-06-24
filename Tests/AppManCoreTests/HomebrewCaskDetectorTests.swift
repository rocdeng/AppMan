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
