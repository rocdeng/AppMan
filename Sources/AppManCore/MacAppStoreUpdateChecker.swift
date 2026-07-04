import Foundation

public struct MacAppStoreUpdateChecker: AppUpdateChecking {
    private let countryCode: String?
    private let appStoreIDProvider: @Sendable (AppRecord) -> String?
    private let fetchData: @Sendable (URL) throws -> Data

    public init(
        countryCode: String? = Locale.current.region?.identifier.lowercased() ?? "us",
        appStoreIDProvider: (@Sendable (AppRecord) -> String?)? = nil,
        fetchData: @escaping @Sendable (URL) throws -> Data = { url in
            try Data(contentsOf: url)
        }
    ) {
        self.countryCode = countryCode
        self.appStoreIDProvider = appStoreIDProvider ?? { app in
            MacAppStoreAdamIDProvider.appStoreAdamID(for: app)
        }
        self.fetchData = fetchData
    }

    public func checkUpdates(for apps: [AppRecord]) throws -> [AppRecord] {
        try LimitedConcurrentMap.map(apps, limit: 3) { app in
            guard case .macAppStore = app.installSource else {
                var updatedApp = app
                updatedApp.updateStatus = .unsupported(reason: "暂不支持此安装渠道")
                return updatedApp
            }

            return try checkUpdate(for: app)
        }
    }

    private func checkUpdate(for app: AppRecord) throws -> AppRecord {
        var updatedApp = app

        guard let bundleIdentifier = app.bundleIdentifier, !bundleIdentifier.isEmpty else {
            updatedApp.updateStatus = .unsupported(reason: "缺少 Bundle ID，无法查询 App Store")
            return updatedApp
        }

        let lookupURLs = makeLookupURLs(bundleIdentifier: bundleIdentifier, appStoreID: appStoreIDProvider(app))
        guard !lookupURLs.isEmpty else {
            updatedApp.updateStatus = .checkFailed(message: "无法构造 App Store 查询地址")
            return updatedApp
        }

        var lastError: Error?
        do {
            for lookupURL in lookupURLs {
                let data = try fetchData(lookupURL)
                let response = try JSONDecoder().decode(AppStoreLookupResponse.self, from: data)
                if let result = response.results.first {
                    updatedApp.updateURL = Self.makeMacAppStoreURL(
                        trackID: result.trackID,
                        trackViewURL: result.trackViewURL
                    )
                    if AppVersionComparator.isLatestVersion(result.version, newerThan: app.shortVersion) {
                        updatedApp.updateStatus = .updateAvailable(
                            installedVersion: app.shortVersion,
                            latestVersion: result.version
                        )
                    } else {
                        updatedApp.updateStatus = .upToDate
                    }
                    return updatedApp
                }
            }
        } catch {
            lastError = error
        }

        if let lastError {
            updatedApp.updateStatus = .checkFailed(message: lastError.localizedDescription)
        } else {
            updatedApp.updateStatus = .unsupported(reason: "App Store 未找到此 App")
        }

        return updatedApp
    }

    private func makeLookupURLs(bundleIdentifier: String, appStoreID: String?) -> [URL] {
        var urls: [URL] = []
        urls.append(contentsOf: makeLookupURLs(queryName: "bundleId", queryValue: bundleIdentifier))
        if let appStoreID, !appStoreID.isEmpty {
            urls.append(contentsOf: makeLookupURLs(queryName: "id", queryValue: appStoreID))
        }
        return urls
    }

    private func makeLookupURLs(queryName: String, queryValue: String) -> [URL] {
        var urls: [URL] = []
        if let countryCode {
            if let url = makeLookupURL(queryName: queryName, queryValue: queryValue, countryCode: countryCode) {
                urls.append(url)
            }
        }
        if let url = makeLookupURL(queryName: queryName, queryValue: queryValue, countryCode: nil) {
            urls.append(url)
        }
        return urls
    }

    private func makeLookupURL(queryName: String, queryValue: String, countryCode: String?) -> URL? {
        var components = URLComponents()
        components.scheme = "https"
        components.host = "itunes.apple.com"
        components.path = "/lookup"
        components.queryItems = [
            URLQueryItem(name: queryName, value: queryValue),
        ]
        if let countryCode {
            components.queryItems?.append(URLQueryItem(name: "country", value: countryCode))
        }
        return components.url
    }

    private static func makeMacAppStoreURL(trackID: Int?, trackViewURL: URL?) -> URL? {
        if let trackID {
            return URL(string: "macappstore://itunes.apple.com/app/id\(trackID)")
        }

        guard let trackViewURL else {
            return nil
        }

        let absoluteString = trackViewURL.absoluteString
        if let range = absoluteString.range(of: #"id[0-9]+"#, options: .regularExpression) {
            return URL(string: "macappstore://itunes.apple.com/app/\(absoluteString[range])")
        }

        return trackViewURL
    }
}

private struct AppStoreLookupResponse: Decodable {
    let results: [AppStoreLookupResult]
}

private struct AppStoreLookupResult: Decodable {
    let version: String
    let trackID: Int?
    let trackViewURL: URL?

    private enum CodingKeys: String, CodingKey {
        case version
        case trackID = "trackId"
        case trackViewURL = "trackViewUrl"
    }
}

private enum MacAppStoreAdamIDProvider {
    static func appStoreAdamID(for app: AppRecord) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/mdls")
        process.arguments = ["-raw", "-name", "kMDItemAppStoreAdamID", app.path.path]

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        do {
            try process.run()
        } catch {
            return nil
        }

        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            return nil
        }

        let data = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        let output = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let output, output != "(null)", !output.isEmpty else {
            return nil
        }
        return output
    }
}
