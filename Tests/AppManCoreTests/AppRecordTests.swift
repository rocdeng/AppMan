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
