import XCTest
@testable import AppManCore

final class UpdateRecipeValidationServiceTests: XCTestCase {
    func testValidationReturnsLatestVersionAndValidatedPackage() throws {
        let checkURL = URL(string: "https://example.com/releases")!
        let packageURL = URL(string: "https://example.com/App-2.0-arm64.dmg")!
        let recipe = makeRecipe(checkURL: checkURL, downloadURL: packageURL)
        let service = UpdateRecipeValidationService(
            recipeStore: StubRecipeStore(recipes: [recipe]),
            fetchData: { url in
                XCTAssertEqual(url, checkURL)
                return Data("Latest version 2.0".utf8)
            },
            probeDownload: { url in
                XCTAssertEqual(url, packageURL)
                return "HTTP 200，大小 12 MB"
            }
        )

        let app = makeApp()
        XCTAssertEqual(try service.matchingRecipe(for: app), recipe)

        let result = try service.validate(app: app, recipe: recipe)
        XCTAssertEqual(result.latestVersion, "2.0")
        XCTAssertEqual(result.packageURL, packageURL)
        XCTAssertTrue(result.downloadIsValid)
        XCTAssertEqual(result.downloadValidationMessage, "HTTP 200，大小 12 MB")
    }

    func testValidationReportsMissingPackageURL() throws {
        let checkURL = URL(string: "https://example.com/releases")!
        let recipe = makeRecipe(checkURL: checkURL, downloadURL: nil)
        let service = UpdateRecipeValidationService(
            recipeStore: StubRecipeStore(recipes: [recipe]),
            fetchData: { _ in Data("Latest version 2.0".utf8) },
            probeDownload: { _ in XCTFail("不应校验不存在的安装包"); return "" }
        )

        let result = try service.validate(app: makeApp(), recipe: recipe)
        XCTAssertEqual(result.latestVersion, "2.0")
        XCTAssertNil(result.packageURL)
        XCTAssertFalse(result.downloadIsValid)
        XCTAssertEqual(result.downloadValidationMessage, "已获取最新版本，但未抓取到安装包地址")
    }

    private func makeRecipe(checkURL: URL, downloadURL: URL?) -> UpdateRecipe {
        UpdateRecipe(
            id: "com.example.App",
            name: "App",
            recipePrompt: "测试规则",
            match: UpdateRecipe.Match(
                bundleIdentifier: "com.example.App",
                appName: "App",
                officialHost: "example.com"
            ),
            checks: [
                UpdateRecipe.Check(
                    url: checkURL,
                    extract: UpdateRecipe.Extract(
                        type: .regex,
                        pattern: #"Latest version ([0-9.]+)"#,
                        versionGroup: 1
                    )
                ),
            ],
            updatePageURL: checkURL,
            download: downloadURL.map {
                UpdateRecipe.Download(url: $0, sourceURL: nil, pattern: nil, urlGroup: nil)
            }
        )
    }

    private func makeApp() -> AppRecord {
        AppRecord(
            id: "com.example.App",
            name: "App",
            bundleIdentifier: "com.example.App",
            shortVersion: "1.0",
            buildVersion: nil,
            path: URL(fileURLWithPath: "/Applications/App.app"),
            sizeBytes: 1,
            installSource: .manual(reason: "测试")
        )
    }
}

private struct StubRecipeStore: UpdateRecipeStoring {
    let recipes: [UpdateRecipe]

    func load() throws -> [UpdateRecipe] {
        recipes
    }
}
