import Foundation

public protocol SelfUpdateSearching: Sendable {
    func searchOfficialWebsite(for app: AppRecord) throws -> URL?
}

public struct GoogleSelfUpdateSearcher: SelfUpdateSearching {
    private let fetchData: @Sendable (URL) throws -> Data

    public init(fetchData: @escaping @Sendable (URL) throws -> Data = { url in
        try Data(contentsOf: url)
    }) {
        self.fetchData = fetchData
    }

    public func searchOfficialWebsite(for app: AppRecord) throws -> URL? {
        guard let url = searchURL(for: app) else {
            return nil
        }

        let data = try fetchData(url)
        guard let html = String(data: data, encoding: .utf8) else {
            return nil
        }
        return GoogleSearchResultParser.firstCandidateURL(in: html)
    }

    private func searchURL(for app: AppRecord) -> URL? {
        var components = URLComponents()
        components.scheme = "https"
        components.host = "www.google.com"
        components.path = "/search"
        let bundlePart = app.bundleIdentifier.map { " \($0)" } ?? ""
        components.queryItems = [
            URLQueryItem(name: "q", value: "\(app.name)\(bundlePart) mac official download"),
        ]
        return components.url
    }
}

public struct PreferredSelfUpdateSearcher: SelfUpdateSearching {
    private let tinyFishAPIKey: String
    private let tinyFishSearcher: TinyFishSelfUpdateSearcher
    private let googleSearcher: GoogleSelfUpdateSearcher

    public init(
        tinyFishAPIKey: String,
        tinyFishSearcher: TinyFishSelfUpdateSearcher? = nil,
        googleSearcher: GoogleSelfUpdateSearcher = GoogleSelfUpdateSearcher()
    ) {
        self.tinyFishAPIKey = tinyFishAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)
        self.tinyFishSearcher = tinyFishSearcher ?? TinyFishSelfUpdateSearcher(apiKey: tinyFishAPIKey)
        self.googleSearcher = googleSearcher
    }

    public func searchOfficialWebsite(for app: AppRecord) throws -> URL? {
        if !tinyFishAPIKey.isEmpty {
            return try tinyFishSearcher.searchOfficialWebsite(for: app)
        }
        return try googleSearcher.searchOfficialWebsite(for: app)
    }
}

public struct TinyFishSelfUpdateSearcher: SelfUpdateSearching {
    private let apiKey: String
    private let fetchData: @Sendable (URL, [String: String]) throws -> Data

    public init(
        apiKey: String,
        fetchData: @escaping @Sendable (URL, [String: String]) throws -> Data = { url, headers in
            try TinyFishSelfUpdateSearcher.defaultFetchData(url: url, headers: headers)
        }
    ) {
        self.apiKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        self.fetchData = fetchData
    }

    public func searchOfficialWebsite(for app: AppRecord) throws -> URL? {
        guard !apiKey.isEmpty, let url = searchURL(for: app) else {
            return nil
        }

        let data = try fetchData(url, ["X-API-Key": apiKey])
        let response = try JSONDecoder().decode(TinyFishSearchResponse.self, from: data)
        return response.results
            .map(\.url)
            .first { GoogleSearchResultParser.isAllowedCandidate($0) }
            .map(GoogleSearchResultParser.normalized)
    }

    private func searchURL(for app: AppRecord) -> URL? {
        var components = URLComponents()
        components.scheme = "https"
        components.host = "api.search.tinyfish.ai"
        let bundlePart = app.bundleIdentifier.map { " \($0)" } ?? ""
        components.queryItems = [
            URLQueryItem(name: "query", value: "\(app.name)\(bundlePart) mac official download"),
            URLQueryItem(name: "limit", value: "10"),
            URLQueryItem(name: "purpose", value: "Find the official website or official download/update page for this macOS app"),
        ]
        return components.url
    }

    public static func defaultFetchData(url: URL, headers: [String: String]) throws -> Data {
        var request = URLRequest(url: url)
        for (field, value) in headers {
            request.setValue(value, forHTTPHeaderField: field)
        }
        return try URLSession.shared.synchronousData(for: request)
    }
}

private struct TinyFishSearchResponse: Decodable {
    let results: [TinyFishSearchResult]
}

private struct TinyFishSearchResult: Decodable {
    let url: URL
}

public struct SelfHostedUpdateChecker: AppUpdateChecking {
    private let sourceStore: SelfUpdateSourceStore
    private let googleSearcher: any SelfUpdateSearching
    private let recipeStore: any UpdateRecipeStoring
    private let fetchData: @Sendable (URL) throws -> Data

    public init(
        sourceStore: SelfUpdateSourceStore = SelfUpdateSourceStore(),
        googleSearcher: any SelfUpdateSearching = GoogleSelfUpdateSearcher(),
        recipeStore: any UpdateRecipeStoring = FileUpdateRecipeStore(),
        fetchData: @escaping @Sendable (URL) throws -> Data = { url in
            try SelfHostedUpdateChecker.defaultFetchData(url)
        }
    ) {
        self.sourceStore = sourceStore
        self.googleSearcher = googleSearcher
        self.recipeStore = recipeStore
        self.fetchData = fetchData
    }

    public func checkUpdates(for apps: [AppRecord]) throws -> [AppRecord] {
        let sourceRecords = try sourceStore.load()
        let recipes = try recipeStore.load()
        return try LimitedConcurrentMap.map(apps, limit: 3) { app in
            guard case .manual = app.installSource else {
                var updatedApp = app
                updatedApp.updateStatus = .unsupported(reason: "暂不支持此安装渠道")
                return updatedApp
            }

            return try checkUpdate(for: app, sourceRecords: sourceRecords, recipes: recipes)
        }
    }

    private func checkUpdate(
        for app: AppRecord,
        sourceRecords: [SelfUpdateSourceRecord],
        recipes: [UpdateRecipe]
    ) throws -> AppRecord {
        var updatedApp = app

        if let recipe = UpdateRecipeMatcher.bestRecipe(for: app, in: recipes) {
            return checkUpdate(for: app, recipe: recipe)
        }

        if let source = Self.sourceRecord(for: app, in: sourceRecords) {
            if let recipe = UpdateRecipeMatcher.bestRecipe(for: app, in: recipes, officialURL: source.updateURL) {
                return checkUpdate(for: app, recipe: recipe)
            }
            return checkUpdate(for: app, updateURL: source.updateURL)
        }

        do {
            if let candidateURL = try googleSearcher.searchOfficialWebsite(for: app) {
                if let recipe = UpdateRecipeMatcher.bestRecipe(for: app, in: recipes, officialURL: candidateURL) {
                    return checkUpdate(for: app, recipe: recipe)
                }
                updatedApp.updateURL = candidateURL
                updatedApp.updateStatus = .needsOfficialWebsiteConfirmation(candidateURL: candidateURL)
            } else {
                updatedApp.updateStatus = .needsManualUpdateURL
            }
        } catch {
            updatedApp.updateStatus = .needsManualUpdateURL
        }

        return updatedApp
    }

    private func checkUpdate(for app: AppRecord, recipe: UpdateRecipe) -> AppRecord {
        var updatedApp = app
        updatedApp.updateURL = recipe.updatePageURL ?? recipe.checks.first?.url
        updatedApp.updateURLIsDirectDownload = false

        do {
            let runner = UpdateRecipeRunner(fetchData: fetchData)
            guard let release = try runner.latestRelease(using: recipe) else {
                updatedApp.updateStatus = .needsManualUpdateURL
                return updatedApp
            }

            let latestVersion = release.latestVersion
            if AppVersionComparator.isLatestVersion(latestVersion, newerThan: app.shortVersion) {
                if let packageURL = release.packageURL {
                    updatedApp.updateURL = packageURL
                    updatedApp.updateURLIsDirectDownload = true
                }
                updatedApp.updateStatus = .updateAvailable(
                    installedVersion: app.shortVersion,
                    latestVersion: latestVersion
                )
            } else {
                updatedApp.updateStatus = .upToDate
            }
        } catch {
            updatedApp.updateStatus = .checkFailed(message: error.localizedDescription)
        }

        return updatedApp
    }

    public static func defaultFetchData(_ url: URL) throws -> Data {
        var request = URLRequest(url: url)
        request.setValue("AppMan", forHTTPHeaderField: "User-Agent")
        return try URLSession.shared.synchronousData(for: request)
    }

    private static func sourceRecord(for app: AppRecord, in records: [SelfUpdateSourceRecord]) -> SelfUpdateSourceRecord? {
        if let record = records.first(where: { $0.id == app.id }) {
            return record
        }

        guard let bundleIdentifier = app.bundleIdentifier else {
            return nil
        }
        return records.first { $0.bundleIdentifier == bundleIdentifier }
    }

    private func checkUpdate(for app: AppRecord, updateURL: URL) -> AppRecord {
        var updatedApp = app
        updatedApp.updateURL = updateURL
        updatedApp.updateURLIsDirectDownload = false

        do {
            let data = try fetchData(updateURL)
            guard let html = String(data: data, encoding: .utf8),
                  let latestVersion = WebPageVersionParser.latestVersion(in: html) else {
                updatedApp.updateStatus = .undetectable
                return updatedApp
            }

            if AppVersionComparator.isLatestVersion(latestVersion, newerThan: app.shortVersion) {
                if let packageURL = PackageURLParser.bestPackageURL(
                    in: html,
                    baseURL: updateURL,
                    latestVersion: latestVersion
                ) {
                    updatedApp.updateURL = packageURL
                    updatedApp.updateURLIsDirectDownload = true
                }
                updatedApp.updateStatus = .updateAvailable(
                    installedVersion: app.shortVersion,
                    latestVersion: latestVersion
                )
            } else {
                updatedApp.updateStatus = .upToDate
            }
        } catch {
            updatedApp.updateStatus = .checkFailed(message: error.localizedDescription)
        }

        return updatedApp
    }
}

private enum GoogleSearchResultParser {
    static func firstCandidateURL(in html: String) -> URL? {
        let patterns = [
            #"/url\?q=(https?://[^"&]+)"#,
            #"href="(https?://[^"]+)""#,
        ]

        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern) else {
                continue
            }
            let range = NSRange(html.startIndex..<html.endIndex, in: html)
            let matches = regex.matches(in: html, range: range)
            for match in matches {
                guard match.numberOfRanges > 1,
                      let urlRange = Range(match.range(at: 1), in: html) else {
                    continue
                }
                let rawValue = String(html[urlRange])
                guard let decodedValue = rawValue.removingPercentEncoding ?? rawValue as String?,
                      let url = URL(string: decodedValue),
                      isAllowedCandidate(url) else {
                    continue
                }
                return normalized(url)
            }
        }

        return nil
    }

    static func isAllowedCandidate(_ url: URL) -> Bool {
        guard let host = url.host(percentEncoded: false)?.lowercased() else {
            return false
        }

        let blockedHosts = [
            "google.",
            "support.google.",
            "webcache.googleusercontent.",
            "youtube.",
            "apps.apple.",
            "itunes.apple.",
            "apps.microsoft.",
            "github.com",
            "sourceforge.net",
            "macupdate.com",
            "softonic.com",
            "cnet.com",
        ]

        return !blockedHosts.contains { host == $0 || host.contains($0) }
    }

    static func normalized(_ url: URL) -> URL {
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        components?.query = nil
        components?.fragment = nil
        return components?.url ?? url
    }
}

private extension URLSession {
    func synchronousData(for request: URLRequest) throws -> Data {
        let semaphore = DispatchSemaphore(value: 0)
        var result: Result<Data, Error>!
        dataTask(with: request) { data, _, error in
            if let error {
                result = .failure(error)
            } else {
                result = .success(data ?? Data())
            }
            semaphore.signal()
        }.resume()
        semaphore.wait()
        return try result.get()
    }
}

private enum WebPageVersionParser {
    static func latestVersion(in html: String) -> String? {
        let patterns = [
            #"(?i)(?:latest\s+version|version|download|release)\D{0,32}v?([0-9]+(?:\.[0-9A-Za-z]+){1,5})(?=[^0-9A-Za-z]|$)"#,
            #"(?i)\bv([0-9]+(?:\.[0-9A-Za-z]+){1,5})(?=[^0-9A-Za-z]|$)"#,
        ]
        var versions: [String] = []

        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern) else {
                continue
            }
            let range = NSRange(html.startIndex..<html.endIndex, in: html)
            for match in regex.matches(in: html, range: range) {
                guard match.numberOfRanges > 1,
                      let versionRange = Range(match.range(at: 1), in: html) else {
                    continue
                }
                versions.append(Self.normalizedVersion(String(html[versionRange])))
            }
        }

        return versions.max { first, second in
            first.compare(second, options: .numeric) == .orderedAscending
        }
    }

    private static func normalizedVersion(_ value: String) -> String {
        value.replacingOccurrences(
            of: #"(?i)\.(?:dmg|pkg|zip)$"#,
            with: "",
            options: .regularExpression
        )
    }
}

enum PackageURLParser {
    static func bestPackageURL(in text: String, baseURL: URL, latestVersion: String? = nil) -> URL? {
        let patterns = [
            #"https?://[^\s"'<>]+?\.(?:dmg|pkg|zip)(?:\?[^\s"'<>]*)?"#,
            #"href\s*=\s*["']([^"']+?\.(?:dmg|pkg|zip)(?:\?[^"']*)?)["']"#,
        ]
        let latestVersion = latestVersion?.lowercased()
        var candidates: [URL] = []

        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
                continue
            }

            let range = NSRange(text.startIndex..<text.endIndex, in: text)
            for match in regex.matches(in: text, range: range) {
                let captureIndex = match.numberOfRanges > 1 ? 1 : 0
                guard let urlRange = Range(match.range(at: captureIndex), in: text) else {
                    continue
                }

                let rawValue = String(text[urlRange])
                    .replacingOccurrences(of: "&amp;", with: "&")
                guard let url = URL(string: rawValue, relativeTo: baseURL)?.absoluteURL else {
                    continue
                }
                candidates.append(url)
            }
        }

        guard !candidates.isEmpty else {
            return nil
        }

        if let latestVersion,
           let versionedCandidate = candidates.first(where: {
               $0.lastPathComponent.lowercased().contains(latestVersion)
           }) {
            return versionedCandidate
        }

        return candidates.first
    }
}
