import XCTest
@testable import AppManCore

final class ProcessCommandRunnerTests: XCTestCase {
    func testPassesConfiguredEnvironmentToCommand() throws {
        let runner = ProcessCommandRunner(
            searchDirectories: [URL(fileURLWithPath: "/bin")],
            environment: ["APPMAN_TEST_VALUE": "ready"]
        )

        let output = try runner.run("sh", arguments: ["-c", "printf %s \"$APPMAN_TEST_VALUE\""])

        XCTAssertEqual(output, "ready")
    }

    func testStopsCommandAfterTimeout() {
        let runner = ProcessCommandRunner(
            searchDirectories: [URL(fileURLWithPath: "/bin")],
            timeout: 0.05
        )

        XCTAssertThrowsError(try runner.run("sleep", arguments: ["1"])) { error in
            XCTAssertEqual(error as? CommandError, .timedOut("sleep"))
        }
    }
}
