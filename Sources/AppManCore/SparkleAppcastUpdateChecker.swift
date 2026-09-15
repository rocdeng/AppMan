import Foundation

public struct SparkleAppcastUpdateChecker: AppUpdateChecking {
    private let fetchData: @Sendable (URL) throws -> Data
    private let recipeStore: any UpdateRecipeStoring

    public init(
        fetchData: @escaping @Sendable (URL) throws -> Data = { url in
            try SparkleAppcastUpdateChecker.defaultFetchData(url)
        },
        recipeStore: any UpdateRecipeStoring = FileUpdateRecipeStore()
    ) {
        self.fetchData = fetchData
        self.recipeStore = recipeStore
    }

    public static func defaultFetchData(_ url: URL) throws -> Data {
        var request = URLRequest(url: url)
        request.timeoutInterval = 30
        request.setValue("AppMan", forHTTPHeaderField: "User-Agent")
        return try URLSession.shared.synchronousData(for: request)
    }

    public func checkUpdates(for apps: [AppRecord]) throws -> [AppRecord] {
        try checkUpdates(for: apps, onProgress: { _ in })
    }

    public func checkUpdates(
        for apps: [AppRecord],
        onProgress: @escaping @Sendable (AppRecord) -> Void
    ) throws -> [AppRecord] {
        try LimitedConcurrentMap.map(apps, limit: 3, onResult: onProgress) { app in
            guard case let .sparkle(feedURL) = app.installSource else {
                var updatedApp = app
                updatedApp.updateStatus = .unsupported(reason: "暂不支持此安装渠道")
                return updatedApp
            }

            return try checkUpdate(for: app, feedURL: feedURL)
        }
    }

    private func checkUpdate(for app: AppRecord, feedURL: URL) throws -> AppRecord {
        var updatedApp = app
        updatedApp.updateURL = feedURL
        updatedApp.updateURLIsDirectDownload = false

        do {
            if let recipe = try recipeStore.load().first(where: { recipe in
                recipe.match.bundleIdentifier == app.bundleIdentifier
                    || recipe.match.appName?.localizedCaseInsensitiveCompare(app.name) == .orderedSame
            }),
               !recipe.checks.isEmpty,
               let release = try UpdateRecipeRunner(fetchData: fetchData).latestRelease(using: recipe) {
                return applying(
                    latestVersion: release.latestVersion,
                    packageURL: release.packageURL,
                    installedVersion: recipe.installedVersion(for: app),
                    to: app,
                    fallbackURL: recipe.updatePageURL ?? feedURL
                )
            }

            let data = try fetchData(feedURL)
            guard let release = SparkleReleaseParser.parseLatestRelease(from: data, baseURL: feedURL) else {
                updatedApp.updateStatus = .checkFailed(message: "Sparkle appcast 中没有版本信息")
                return updatedApp
            }

            return applying(
                latestVersion: release.latestVersion,
                packageURL: release.packageURL,
                to: app,
                fallbackURL: feedURL
            )
        } catch {
            updatedApp.updateStatus = .checkFailed(message: error.localizedDescription)
        }

        return updatedApp
    }

    private func applying(
        latestVersion: String,
        packageURL: URL?,
        installedVersion: String? = nil,
        to app: AppRecord,
        fallbackURL: URL
    ) -> AppRecord {
        var updatedApp = app
        updatedApp.updateURL = fallbackURL
        updatedApp.updateURLIsDirectDownload = false

        let installedVersion = installedVersion ?? app.shortVersion
        if AppVersionComparator.isLatestVersion(latestVersion, newerThan: installedVersion) {
            if let packageURL {
                updatedApp.updateURL = packageURL
                updatedApp.updateURLIsDirectDownload = true
            }
            updatedApp.updateStatus = .updateAvailable(
                installedVersion: installedVersion,
                latestVersion: latestVersion
            )
        } else {
            updatedApp.updateStatus = .upToDate
        }
        return updatedApp
    }
}
