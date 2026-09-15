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
    private let detectors: [any SelfHostedUpdateDetecting]
    private let fetchData: @Sendable (URL) throws -> Data

    public init(
        sourceStore: SelfUpdateSourceStore = SelfUpdateSourceStore(),
        googleSearcher: any SelfUpdateSearching = GoogleSelfUpdateSearcher(),
        recipeStore: any UpdateRecipeStoring = FileUpdateRecipeStore(),
        detectors: [any SelfHostedUpdateDetecting]? = nil,
        fetchData: @escaping @Sendable (URL) throws -> Data = { url in
            try SelfHostedUpdateChecker.defaultFetchData(url)
        }
    ) {
        self.sourceStore = sourceStore
        self.googleSearcher = googleSearcher
        self.recipeStore = recipeStore
        self.fetchData = fetchData
        self.detectors = detectors ?? SelfHostedUpdateChecker.defaultDetectors(fetchData: fetchData)
    }

    public func checkUpdates(for apps: [AppRecord]) throws -> [AppRecord] {
        try checkUpdates(for: apps, onProgress: { _ in })
    }

    public func checkUpdates(
        for apps: [AppRecord],
        onProgress: @escaping @Sendable (AppRecord) -> Void
    ) throws -> [AppRecord] {
        let sourceRecords = try sourceStore.load()
        let recipes = try recipeStore.load()
        return try LimitedConcurrentMap.map(apps, limit: 3, onResult: onProgress) { app in
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
            return checkUpdate(for: app, updateURL: source.updateURL, detectors: detectors)
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
        let installedVersion = recipe.installedVersion(for: app)
        updatedApp.updateURL = recipe.updatePageURL ?? recipe.checks.first?.url
        updatedApp.updateURLIsDirectDownload = false

        do {
            let runner = UpdateRecipeRunner(fetchData: fetchData)
            guard let release = try runner.latestRelease(using: recipe) else {
                updatedApp.updateStatus = .needsManualUpdateURL
                return updatedApp
            }

            let latestVersion = release.latestVersion
            if AppVersionComparator.isLatestVersion(latestVersion, newerThan: installedVersion) {
                if let packageURL = release.packageURL {
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

    private static func defaultDetectors(
        fetchData: @escaping @Sendable (URL) throws -> Data
    ) -> [any SelfHostedUpdateDetecting] {
        [
            GitHubReleaseUpdateDetector(fetchData: fetchData),
            SparkleFeedUpdateDetector(fetchData: fetchData),
            JSONAPIUpdateDetector(fetchData: fetchData),
            RedirectDownloadUpdateDetector(),
            GenericWebPageUpdateDetector(fetchData: fetchData),
        ]
    }

    private func checkUpdate(
        for app: AppRecord,
        updateURL: URL,
        detectors: [any SelfHostedUpdateDetecting]
    ) -> AppRecord {
        var updatedApp = app
        updatedApp.updateURL = updateURL
        updatedApp.updateURLIsDirectDownload = false

        do {
            guard let release = try Self.detectRelease(for: app, updateURL: updateURL, detectors: detectors) else {
                updatedApp.updateStatus = .undetectable
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

    private static func detectRelease(
        for app: AppRecord,
        updateURL: URL,
        detectors: [any SelfHostedUpdateDetecting]
    ) throws -> SelfHostedRelease? {
        for detector in detectors {
            if let release = try detector.detectRelease(for: app, updateURL: updateURL) {
                return release
            }
        }
        return nil
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

extension URLSession {
    func synchronousData(for request: URLRequest) throws -> Data {
        let semaphore = DispatchSemaphore(value: 0)
        var result: Result<Data, Error>!
        dataTask(with: request) { data, response, error in
            if let error {
                result = .failure(error)
            } else if let response = response as? HTTPURLResponse,
                      !(200...299).contains(response.statusCode) {
                result = .failure(HTTPStatusError(statusCode: response.statusCode, url: request.url))
            } else {
                result = .success(data ?? Data())
            }
            semaphore.signal()
        }.resume()
        semaphore.wait()
        return try result.get()
    }
}

private struct HTTPStatusError: LocalizedError {
    let statusCode: Int
    let url: URL?

    var errorDescription: String? {
        if let url {
            return "HTTP \(statusCode)：\(url.host() ?? url.absoluteString)"
        }
        return "HTTP \(statusCode)"
    }
}

public protocol SelfHostedUpdateDetecting: Sendable {
    func detectRelease(for app: AppRecord, updateURL: URL) throws -> SelfHostedRelease?
}

public struct SelfHostedRelease: Equatable, Sendable {
    public let latestVersion: String
    public let packageURL: URL?

    public init(latestVersion: String, packageURL: URL?) {
        self.latestVersion = latestVersion
        self.packageURL = packageURL
    }
}

public struct GitHubReleaseUpdateDetector: SelfHostedUpdateDetecting {
    private let fetchData: @Sendable (URL) throws -> Data
    private let targetArchitecture: PackageTargetArchitecture

    public init(
        targetArchitecture: PackageTargetArchitecture = .current,
        fetchData: @escaping @Sendable (URL) throws -> Data
    ) {
        self.targetArchitecture = targetArchitecture
        self.fetchData = fetchData
    }

    public func detectRelease(for app: AppRecord, updateURL: URL) throws -> SelfHostedRelease? {
        guard let repository = GitHubRepository(url: updateURL) else {
            return nil
        }

        let data = try fetchData(repository.latestReleaseAPIURL)
        let release = try JSONDecoder().decode(GitHubLatestRelease.self, from: data)
        let latestVersion = release.tagName.removingVersionPrefix()
        guard !latestVersion.isEmpty else {
            return nil
        }

        return SelfHostedRelease(
            latestVersion: latestVersion,
            packageURL: Self.bestMacPackageURL(
                in: release.assets.map(\.browserDownloadURL),
                latestVersion: latestVersion,
                targetArchitecture: targetArchitecture
            )
        )
    }

    private static func bestMacPackageURL(
        in urls: [URL],
        latestVersion: String,
        targetArchitecture: PackageTargetArchitecture
    ) -> URL? {
        let packageURLs = urls.filter { PackageURLParser.isPackageURL($0) }
        guard !packageURLs.isEmpty else {
            return nil
        }

        let latestVersionForms = versionForms(for: latestVersion)
        let macKeywords = ["macos", "darwin", "osx", "mac", "arm64", "aarch64", "universal"]
        let blockedKeywords = ["windows", "win32", "win64", "linux", "android", "x86_64-pc-windows"]

        func score(_ url: URL) -> Int {
            let path = url.lastPathComponent.lowercased()
            var score = 0
            if latestVersionForms.contains(where: { path.contains($0) }) {
                score += 20
            }
            if macKeywords.contains(where: { path.contains($0) }) {
                score += 10
            }
            score += targetArchitecture.score(packageName: path)
            if blockedKeywords.contains(where: { path.contains($0) }) {
                score -= 100
            }
            if url.pathExtension.lowercased() == "dmg" {
                score += 2
            }
            return score
        }

        return packageURLs.max { score($0) < score($1) }
    }

    private static func versionForms(for version: String) -> [String] {
        [
            version,
            version.replacingOccurrences(of: ".", with: "_"),
            version.replacingOccurrences(of: ".", with: ""),
        ].map { $0.lowercased() }
    }
}

public enum PackageTargetArchitecture: Sendable {
    case appleSilicon
    case intel

    public static var current: PackageTargetArchitecture {
        #if arch(arm64)
        return .appleSilicon
        #else
        return .intel
        #endif
    }

    func score(packageName: String) -> Int {
        switch self {
        case .appleSilicon:
            if containsAny(["arm64", "aarch64", "apple-silicon", "applesilicon", "universal"], in: packageName) {
                return 40
            }
            if containsAny(["x64", "x86_64", "amd64", "intel", "macos-64", "darwin-64"], in: packageName) {
                return -30
            }
        case .intel:
            if containsAny(["x64", "x86_64", "amd64", "intel", "macos-64", "darwin-64"], in: packageName) {
                return 40
            }
            if containsAny(["arm64", "aarch64", "apple-silicon", "applesilicon"], in: packageName) {
                return -30
            }
            if packageName.contains("universal") {
                return 10
            }
        }
        return 0
    }

    private func containsAny(_ keywords: [String], in value: String) -> Bool {
        keywords.contains { value.contains($0) }
    }
}

private struct GitHubRepository {
    let owner: String
    let name: String

    init?(url: URL) {
        guard url.host(percentEncoded: false)?.lowercased() == "github.com" else {
            return nil
        }

        let components = url.pathComponents.filter { $0 != "/" }
        guard components.count >= 2 else {
            return nil
        }

        owner = components[0]
        name = components[1]
    }

    var latestReleaseAPIURL: URL {
        URL(string: "https://api.github.com/repos/\(owner)/\(name)/releases/latest")!
    }
}

private struct GitHubLatestRelease: Decodable {
    let tagName: String
    let assets: [Asset]

    private enum CodingKeys: String, CodingKey {
        case tagName = "tag_name"
        case assets
    }

    struct Asset: Decodable {
        let browserDownloadURL: URL

        private enum CodingKeys: String, CodingKey {
            case browserDownloadURL = "browser_download_url"
        }
    }
}

public struct GenericWebPageUpdateDetector: SelfHostedUpdateDetecting {
    private let fetchData: @Sendable (URL) throws -> Data

    public init(fetchData: @escaping @Sendable (URL) throws -> Data) {
        self.fetchData = fetchData
    }

    public func detectRelease(for app: AppRecord, updateURL: URL) throws -> SelfHostedRelease? {
        let data = try fetchData(updateURL)
        guard let html = String(data: data, encoding: .utf8),
              let latestVersion = WebPageVersionParser.latestVersion(in: html) else {
            return nil
        }

        return SelfHostedRelease(
            latestVersion: latestVersion,
            packageURL: PackageURLParser.bestPackageURL(
                in: html,
                baseURL: updateURL,
                latestVersion: latestVersion
            )
        )
    }
}

public struct SparkleFeedUpdateDetector: SelfHostedUpdateDetecting {
    private let fetchData: @Sendable (URL) throws -> Data

    public init(fetchData: @escaping @Sendable (URL) throws -> Data) {
        self.fetchData = fetchData
    }

    public func detectRelease(for app: AppRecord, updateURL: URL) throws -> SelfHostedRelease? {
        let data = try fetchData(updateURL)
        return SparkleReleaseParser.parseLatestRelease(from: data, baseURL: updateURL)
    }
}

final class SparkleReleaseParser: NSObject, XMLParserDelegate {
    private struct Item {
        let version: String
        let packageURL: URL?
    }

    private let baseURL: URL
    private var items: [Item] = []
    private var currentVersion: String?
    private var currentPackageURL: URL?
    private var capturedText = ""
    private var isInsideItem = false

    init(baseURL: URL) {
        self.baseURL = baseURL
    }

    static func parseLatestRelease(from data: Data, baseURL: URL) -> SelfHostedRelease? {
        let delegate = SparkleReleaseParser(baseURL: baseURL)
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        guard parser.parse() else {
            return nil
        }
        return delegate.latestRelease
    }

    private var latestRelease: SelfHostedRelease? {
        guard let item = items.max(by: { first, second in
            first.version.compare(second.version, options: .numeric) == .orderedAscending
        }) else {
            return nil
        }
        return SelfHostedRelease(latestVersion: item.version, packageURL: item.packageURL)
    }

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        capturedText = ""

        if elementName == "item" {
            isInsideItem = true
            currentVersion = nil
            currentPackageURL = nil
        }

        guard isInsideItem else {
            return
        }

        if let shortVersion = sparkleValue(named: "shortVersionString", in: attributeDict) {
            currentVersion = shortVersion.removingVersionPrefix()
        } else if let buildVersion = sparkleValue(named: "version", in: attributeDict) {
            currentVersion = buildVersion.removingVersionPrefix()
        }

        if currentPackageURL == nil,
           let urlValue = attributeValue(named: "url", in: attributeDict),
           let packageURL = URL(string: urlValue, relativeTo: baseURL)?.absoluteURL,
           PackageURLParser.isPackageURL(packageURL) {
            currentPackageURL = packageURL
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        capturedText += string
    }

    func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?
    ) {
        defer {
            capturedText = ""
        }

        if elementName == "item" {
            if let currentVersion {
                items.append(Item(version: currentVersion, packageURL: currentPackageURL))
            }
            isInsideItem = false
            currentVersion = nil
            currentPackageURL = nil
            return
        }

        guard isInsideItem else {
            return
        }

        let name = qName ?? elementName
        let value = capturedText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else {
            return
        }

        if currentVersion == nil, name.hasSuffix("shortVersionString") || name.hasSuffix("version") {
            currentVersion = value.removingVersionPrefix()
        } else if currentPackageURL == nil,
                  let url = URL(string: value, relativeTo: baseURL)?.absoluteURL,
                  PackageURLParser.isPackageURL(url) {
            currentPackageURL = url
        }
    }

    private func sparkleValue(named suffix: String, in attributes: [String: String]) -> String? {
        for (key, value) in attributes where key.hasSuffix(suffix) && !value.isEmpty {
            return value
        }
        return nil
    }

    private func attributeValue(named name: String, in attributes: [String: String]) -> String? {
        for (key, value) in attributes where key == name || key.hasSuffix(":\(name)") {
            return value.isEmpty ? nil : value
        }
        return nil
    }
}

public struct JSONAPIUpdateDetector: SelfHostedUpdateDetecting {
    private let fetchData: @Sendable (URL) throws -> Data

    public init(fetchData: @escaping @Sendable (URL) throws -> Data) {
        self.fetchData = fetchData
    }

    public func detectRelease(for app: AppRecord, updateURL: URL) throws -> SelfHostedRelease? {
        let data = try fetchData(updateURL)
        let object: Any
        do {
            object = try JSONSerialization.jsonObject(with: data)
        } catch {
            return nil
        }
        return Self.extractRelease(from: object)
    }

    private static func extractRelease(from object: Any) -> SelfHostedRelease? {
        var versions: [String] = []
        var packageURLs: [URL] = []
        collectCandidates(from: object, versions: &versions, packageURLs: &packageURLs)

        guard let latestVersion = versions.max(by: { first, second in
            first.compare(second, options: .numeric) == .orderedAscending
        }) else {
            return nil
        }

        return SelfHostedRelease(
            latestVersion: latestVersion,
            packageURL: bestPackageURL(in: packageURLs, latestVersion: latestVersion)
        )
    }

    private static func collectCandidates(from object: Any, versions: inout [String], packageURLs: inout [URL]) {
        if let string = object as? String {
            if let url = URL(string: string), PackageURLParser.isPackageURL(url) {
                packageURLs.append(url)
            }
            if let version = VersionStringParser.firstVersion(in: string) {
                versions.append(version)
            }
            return
        }

        if let array = object as? [Any] {
            for value in array {
                collectCandidates(from: value, versions: &versions, packageURLs: &packageURLs)
            }
            return
        }

        guard let dictionary = object as? [String: Any] else {
            return
        }

        for (key, value) in dictionary {
            let normalizedKey = key.lowercased()
            if normalizedKey.contains("version"),
               let version = value as? String {
                versions.append(version.removingVersionPrefix())
            }

            if (normalizedKey.contains("url") || normalizedKey.contains("download")),
               let urlString = value as? String,
               let url = URL(string: urlString),
               PackageURLParser.isPackageURL(url) {
                packageURLs.append(url)
            }

            collectCandidates(from: value, versions: &versions, packageURLs: &packageURLs)
        }
    }

    private static func bestPackageURL(in urls: [URL], latestVersion: String) -> URL? {
        PackageURLParser.bestPackageURL(
            in: urls.map(\.absoluteString).joined(separator: "\n"),
            baseURL: URL(string: "https://example.invalid")!,
            latestVersion: latestVersion
        )
    }
}

public struct RedirectDownloadUpdateDetector: SelfHostedUpdateDetecting {
    private let resolveFinalURL: @Sendable (URL) throws -> URL

    public init() {
        resolveFinalURL = { url in
            try Self.defaultResolveFinalURL(url)
        }
    }

    public init(resolveFinalURL: @escaping @Sendable (URL) throws -> URL) {
        self.resolveFinalURL = resolveFinalURL
    }

    public func detectRelease(for app: AppRecord, updateURL: URL) throws -> SelfHostedRelease? {
        let finalURL = try resolveFinalURL(updateURL)
        guard PackageURLParser.isPackageURL(finalURL),
              let latestVersion = VersionStringParser.firstVersion(in: finalURL.lastPathComponent) else {
            return nil
        }

        return SelfHostedRelease(latestVersion: latestVersion, packageURL: finalURL)
    }

    private static func defaultResolveFinalURL(_ url: URL) throws -> URL {
        var request = URLRequest(url: url)
        request.httpMethod = "HEAD"
        let semaphore = DispatchSemaphore(value: 0)
        var result: URL?
        var requestError: Error?

        let task = URLSession.shared.dataTask(with: request) { _, response, error in
            requestError = error
            result = response?.url
            semaphore.signal()
        }
        task.resume()
        semaphore.wait()

        if let requestError {
            throw requestError
        }
        return result ?? url
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

private enum VersionStringParser {
    static func firstVersion(in text: String) -> String? {
        let patterns = [
            #"(?i)\bv?([0-9]+(?:\.[0-9A-Za-z]+){1,5})(?=[^0-9A-Za-z]|$)"#,
        ]

        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern) else {
                continue
            }

            let range = NSRange(text.startIndex..<text.endIndex, in: text)
            guard let match = regex.firstMatch(in: text, range: range),
                  match.numberOfRanges > 1,
                  let versionRange = Range(match.range(at: 1), in: text) else {
                continue
            }
            return String(text[versionRange]).removingPackageExtension()
        }

        return nil
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

    static func isPackageURL(_ url: URL) -> Bool {
        ["dmg", "pkg", "zip"].contains(url.pathExtension.lowercased())
    }
}

private extension String {
    func removingVersionPrefix() -> String {
        replacingOccurrences(of: #"(?i)^v"#, with: "", options: .regularExpression)
    }

    func removingPackageExtension() -> String {
        replacingOccurrences(
            of: #"(?i)\.(?:dmg|pkg|zip)$"#,
            with: "",
            options: .regularExpression
        )
    }
}
