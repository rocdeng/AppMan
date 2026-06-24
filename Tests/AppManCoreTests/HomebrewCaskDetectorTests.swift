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
        XCTAssertEqual(runner.calls, [
            .init(executable: "brew", arguments: ["info", "--cask", "--json=v2"])
        ])
    }

    func testReturnsNilWhenBrewIsUnavailable() throws {
        let runner = StubCommandRunner(error: CommandError.executableNotFound("brew"))
        let detector = HomebrewCaskDetector(commandRunner: runner)
        let app = makeAppRecord(path: URL(fileURLWithPath: "/Applications/Visual Studio Code.app"))

        let source = try detector.detectInstallSource(for: app)

        XCTAssertNil(source)
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

private final class StubCommandRunner: CommandRunning, @unchecked Sendable {
    struct Call: Equatable {
        let executable: String
        let arguments: [String]
    }

    private(set) var calls: [Call] = []
    private let output: String
    private let error: Error?

    init(output: String = "", error: Error? = nil) {
        self.output = output
        self.error = error
    }

    func run(_ executable: String, arguments: [String]) throws -> String {
        calls.append(.init(executable: executable, arguments: arguments))
        if let error {
            throw error
        }
        return output
    }
}
