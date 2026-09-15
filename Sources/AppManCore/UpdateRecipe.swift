import Foundation

public struct UpdateRecipe: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public let name: String
    public let recipePrompt: String?
    public let installedVersionSource: InstalledVersionSource?
    public let match: Match
    public let checks: [Check]
    public let updatePageURL: URL?
    public let download: Download?

    public init(
        id: String,
        name: String,
        recipePrompt: String?,
        installedVersionSource: InstalledVersionSource? = nil,
        match: Match,
        checks: [Check],
        updatePageURL: URL?,
        download: Download? = nil
    ) {
        self.id = id
        self.name = name
        self.recipePrompt = recipePrompt
        self.installedVersionSource = installedVersionSource
        self.match = match
        self.checks = checks
        self.updatePageURL = updatePageURL
        self.download = download
    }

    public struct Match: Codable, Equatable, Sendable {
        public let bundleIdentifier: String?
        public let appName: String?
        public let officialHost: String?

        public init(bundleIdentifier: String?, appName: String?, officialHost: String?) {
            self.bundleIdentifier = bundleIdentifier
            self.appName = appName
            self.officialHost = officialHost
        }
    }

    public struct Check: Codable, Equatable, Sendable {
        public let url: URL
        public let extract: Extract

        public init(url: URL, extract: Extract) {
            self.url = url
            self.extract = extract
        }
    }

    public struct Extract: Codable, Equatable, Sendable {
        public let type: ExtractType
        public let pattern: String
        public let versionGroup: Int

        public init(type: ExtractType, pattern: String, versionGroup: Int) {
            self.type = type
            self.pattern = pattern
            self.versionGroup = versionGroup
        }
    }

    public enum ExtractType: String, Codable, Equatable, Sendable {
        case regex
        case linkRegex
    }

    public enum InstalledVersionSource: String, Codable, Equatable, Sendable {
        case shortVersion
        case buildVersion
    }

    func installedVersion(for app: AppRecord) -> String? {
        switch installedVersionSource ?? .shortVersion {
        case .shortVersion:
            return app.shortVersion
        case .buildVersion:
            return app.buildVersion
        }
    }

    public struct Download: Codable, Equatable, Sendable {
        public let url: URL?
        public let sourceURL: URL?
        public let sourceURLTemplate: String?
        public let pattern: String?
        public let urlGroup: Int?

        public init(
            url: URL?,
            sourceURL: URL?,
            sourceURLTemplate: String? = nil,
            pattern: String?,
            urlGroup: Int?
        ) {
            self.url = url
            self.sourceURL = sourceURL
            self.sourceURLTemplate = sourceURLTemplate
            self.pattern = pattern
            self.urlGroup = urlGroup
        }
    }
}

public protocol UpdateRecipeStoring: Sendable {
    func load() throws -> [UpdateRecipe]
}

public struct FileUpdateRecipeStore: UpdateRecipeStoring {
    private let builtInDirectoryURLs: [URL]
    private let userDirectoryURL: URL
    private let fileManager: FileManager

    public init(
        builtInDirectoryURLs: [URL] = FileUpdateRecipeStore.defaultBuiltInDirectoryURLs(),
        userDirectoryURL: URL = FileUpdateRecipeStore.defaultUserDirectoryURL(),
        fileManager: FileManager = .default
    ) {
        self.builtInDirectoryURLs = builtInDirectoryURLs
        self.userDirectoryURL = userDirectoryURL
        self.fileManager = fileManager
    }

    public func load() throws -> [UpdateRecipe] {
        var recipesByID: [UpdateRecipe.ID: UpdateRecipe] = [:]

        for recipe in try loadRecipes(from: builtInDirectoryURLs) {
            recipesByID[recipe.id] = recipe
        }

        for recipe in try loadRecipes(from: [userDirectoryURL]) {
            recipesByID[recipe.id] = recipe
        }

        return recipesByID.values.sorted {
            $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }

    public static func defaultBuiltInDirectoryURLs() -> [URL] {
        var urls: [URL] = []
        if let resourceURL = Bundle.main.resourceURL {
            urls.append(resourceURL.appendingPathComponent("UpdateRecipes", isDirectory: true))
        }
        urls.append(
            URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
                .appendingPathComponent("Resources/UpdateRecipes", isDirectory: true)
        )
        return urls
    }

    public static func defaultUserDirectoryURL() -> URL {
        AppManSupportDirectory.url()
            .appendingPathComponent("update-recipes", isDirectory: true)
    }

    private func loadRecipes(from directories: [URL]) throws -> [UpdateRecipe] {
        var recipes: [UpdateRecipe] = []
        for directoryURL in directories where fileManager.fileExists(atPath: directoryURL.path) {
            let fileURLs = try fileManager.contentsOfDirectory(
                at: directoryURL,
                includingPropertiesForKeys: nil
            )
            .filter { $0.pathExtension.lowercased() == "json" }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }

            for fileURL in fileURLs {
                let data = try Data(contentsOf: fileURL)
                recipes.append(try JSONDecoder().decode(UpdateRecipe.self, from: data))
            }
        }
        return recipes
    }
}

extension FileUpdateRecipeStore: @unchecked Sendable {}

struct UpdateRecipeRunner: Sendable {
    private let fetchData: @Sendable (URL) throws -> Data

    struct Release: Equatable {
        let latestVersion: String
        let packageURL: URL?
    }

    init(fetchData: @escaping @Sendable (URL) throws -> Data) {
        self.fetchData = fetchData
    }

    func latestVersion(using recipe: UpdateRecipe) throws -> String? {
        try latestRelease(using: recipe)?.latestVersion
    }

    func latestRelease(using recipe: UpdateRecipe) throws -> Release? {
        var versions: [String] = []
        var textsByURL: [(text: String, baseURL: URL)] = []

        for check in recipe.checks {
            let data = try fetchData(check.url)
            guard let text = String(data: data, encoding: .utf8) else {
                continue
            }
            textsByURL.append((text, check.url))
            versions.append(contentsOf: extractVersions(from: text, using: check.extract))
        }

        guard let latestVersion = versions.max(by: { first, second in
            first.compare(second, options: .numeric) == .orderedAscending
        }) else {
            return nil
        }

        let packageURL = try explicitDownloadURL(from: recipe, latestVersion: latestVersion) ?? textsByURL.lazy.compactMap { text, baseURL in
            PackageURLParser.bestPackageURL(in: text, baseURL: baseURL, latestVersion: latestVersion)
        }.first

        return Release(latestVersion: latestVersion, packageURL: packageURL)
    }

    private func explicitDownloadURL(from recipe: UpdateRecipe, latestVersion: String) throws -> URL? {
        guard let download = recipe.download else {
            return nil
        }

        if let url = download.url {
            return url
        }

        let sourceURL = download.sourceURL ?? download.sourceURLTemplate.flatMap { template in
            URL(string: template.replacingOccurrences(of: "{version}", with: latestVersion))
        }
        guard let sourceURL,
              let pattern = download.pattern else {
            return nil
        }

        let data = try fetchData(sourceURL)
        guard let text = String(data: data, encoding: .utf8),
              let regex = try? NSRegularExpression(pattern: pattern) else {
            return nil
        }

        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        let group = download.urlGroup ?? 1
        var candidates: [URL] = []
        for match in regex.matches(in: text, range: range) {
            guard match.numberOfRanges > group,
                  let urlRange = Range(match.range(at: group), in: text) else {
                continue
            }

            let rawValue = String(text[urlRange])
                .replacingOccurrences(of: "&amp;", with: "&")
            if let url = URL(string: rawValue, relativeTo: sourceURL)?.absoluteURL {
                candidates.append(url)
            }
        }

        return Self.bestDownloadCandidate(candidates, latestVersion: latestVersion)
    }

    private static func bestDownloadCandidate(_ candidates: [URL], latestVersion: String) -> URL? {
        guard !candidates.isEmpty else {
            return nil
        }

        let versionForms = Set([
            latestVersion,
            latestVersion.replacingOccurrences(of: ".", with: "_"),
            latestVersion.replacingOccurrences(of: ".", with: ""),
        ].map { $0.lowercased() })

        func score(_ candidate: URL) -> Int {
            let path = candidate.lastPathComponent.lowercased()
            var score = 0
            if versionForms.contains(where: { path.contains($0) }) {
                score += 20
            }
            score += PackageTargetArchitecture.current.score(packageName: path)
            score += Self.operatingSystemCompatibilityScore(packageName: path)
            if candidate.pathExtension.lowercased() == "dmg" {
                score += 2
            }
            return score
        }

        return candidates.max { score($0) < score($1) }
    }

    private static func operatingSystemCompatibilityScore(packageName: String) -> Int {
        guard let regex = try? NSRegularExpression(pattern: #"macos(?:x)?[_-]?(\d+)(?:[_-](\d+))?"#),
              let match = regex.firstMatch(
                in: packageName,
                range: NSRange(packageName.startIndex..<packageName.endIndex, in: packageName)
              ),
              let minimumRange = Range(match.range(at: 1), in: packageName),
              let minimumVersion = Int(packageName[minimumRange]) else {
            return 0
        }

        let parsedMaximumVersion = Range(match.range(at: 2), in: packageName)
            .flatMap { Int(packageName[$0]) }
        let maximumVersion = max(minimumVersion, parsedMaximumVersion ?? minimumVersion)
        let currentVersion = ProcessInfo.processInfo.operatingSystemVersion.majorVersion

        if (minimumVersion...maximumVersion).contains(currentVersion) {
            return 12
        }
        if minimumVersion > currentVersion {
            return -12
        }
        return max(1, 8 - (currentVersion - maximumVersion))
    }

    private func extractVersions(from text: String, using extract: UpdateRecipe.Extract) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: extract.pattern) else {
            return []
        }

        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.matches(in: text, range: range).compactMap { match in
            guard match.numberOfRanges > extract.versionGroup,
                  let versionRange = Range(match.range(at: extract.versionGroup), in: text) else {
                return nil
            }
            return String(text[versionRange])
        }
    }
}

enum UpdateRecipeMatcher {
    static func bestRecipe(
        for app: AppRecord,
        in recipes: [UpdateRecipe],
        officialURL: URL? = nil
    ) -> UpdateRecipe? {
        recipes.first { recipe in
            matches(recipe.match, app: app, officialURL: officialURL)
        }
    }

    private static func matches(
        _ match: UpdateRecipe.Match,
        app: AppRecord,
        officialURL: URL?
    ) -> Bool {
        if let bundleIdentifier = match.bundleIdentifier,
           bundleIdentifier != app.bundleIdentifier {
            return false
        }

        if let appName = match.appName,
           appName.localizedCaseInsensitiveCompare(app.name) != .orderedSame {
            return false
        }

        guard let officialHost = match.officialHost else {
            return match.bundleIdentifier != nil || match.appName != nil
        }

        guard let officialURL else {
            return match.bundleIdentifier != nil || match.appName != nil
        }

        guard let host = officialURL.host(percentEncoded: false)?.lowercased() else {
            return false
        }

        let normalizedOfficialHost = officialHost.lowercased()
        return host == normalizedOfficialHost || host.hasSuffix(".\(normalizedOfficialHost)")
    }
}

public struct UpdateRecipeValidationResult: Equatable, Sendable {
    public let recipe: UpdateRecipe
    public let latestVersion: String?
    public let packageURL: URL?
    public let downloadIsValid: Bool
    public let downloadValidationMessage: String

    public init(
        recipe: UpdateRecipe,
        latestVersion: String?,
        packageURL: URL?,
        downloadIsValid: Bool,
        downloadValidationMessage: String
    ) {
        self.recipe = recipe
        self.latestVersion = latestVersion
        self.packageURL = packageURL
        self.downloadIsValid = downloadIsValid
        self.downloadValidationMessage = downloadValidationMessage
    }
}

public struct UpdateRecipeValidationService: Sendable {
    private let recipeStore: any UpdateRecipeStoring
    private let fetchData: @Sendable (URL) throws -> Data
    private let probeDownload: @Sendable (URL) throws -> String

    public init(
        recipeStore: any UpdateRecipeStoring = FileUpdateRecipeStore(),
        fetchData: @escaping @Sendable (URL) throws -> Data = { try Data(contentsOf: $0) }
    ) {
        self.recipeStore = recipeStore
        self.fetchData = fetchData
        self.probeDownload = { try Self.defaultProbeDownload($0) }
    }

    init(
        recipeStore: any UpdateRecipeStoring,
        fetchData: @escaping @Sendable (URL) throws -> Data,
        probeDownload: @escaping @Sendable (URL) throws -> String
    ) {
        self.recipeStore = recipeStore
        self.fetchData = fetchData
        self.probeDownload = probeDownload
    }

    public func matchingRecipe(for app: AppRecord) throws -> UpdateRecipe? {
        UpdateRecipeMatcher.bestRecipe(for: app, in: try recipeStore.load())
    }

    public func validate(app: AppRecord, recipe: UpdateRecipe) throws -> UpdateRecipeValidationResult {
        let release = try UpdateRecipeRunner(fetchData: fetchData).latestRelease(using: recipe)
        guard let release else {
            return UpdateRecipeValidationResult(
                recipe: recipe,
                latestVersion: nil,
                packageURL: nil,
                downloadIsValid: false,
                downloadValidationMessage: "未能从检查规则中提取版本号"
            )
        }

        guard let packageURL = release.packageURL else {
            return UpdateRecipeValidationResult(
                recipe: recipe,
                latestVersion: release.latestVersion,
                packageURL: nil,
                downloadIsValid: false,
                downloadValidationMessage: "已获取最新版本，但未抓取到安装包地址"
            )
        }

        guard PackageURLParser.isPackageURL(packageURL) else {
            return UpdateRecipeValidationResult(
                recipe: recipe,
                latestVersion: release.latestVersion,
                packageURL: packageURL,
                downloadIsValid: false,
                downloadValidationMessage: "抓取结果不是受支持的 DMG、PKG 或 ZIP 安装包"
            )
        }

        if Self.hasArchitectureConflict(packageURL) {
            return UpdateRecipeValidationResult(
                recipe: recipe,
                latestVersion: release.latestVersion,
                packageURL: packageURL,
                downloadIsValid: false,
                downloadValidationMessage: "安装包架构与当前 Mac 不匹配"
            )
        }

        do {
            let detail = try probeDownload(packageURL)
            return UpdateRecipeValidationResult(
                recipe: recipe,
                latestVersion: release.latestVersion,
                packageURL: packageURL,
                downloadIsValid: true,
                downloadValidationMessage: detail
            )
        } catch {
            return UpdateRecipeValidationResult(
                recipe: recipe,
                latestVersion: release.latestVersion,
                packageURL: packageURL,
                downloadIsValid: false,
                downloadValidationMessage: "安装包地址访问失败：\(error.localizedDescription)"
            )
        }
    }

    private static func hasArchitectureConflict(_ url: URL) -> Bool {
        let name = url.lastPathComponent.lowercased()
        switch PackageTargetArchitecture.current {
        case .appleSilicon:
            return name.contains("x86_64") || name.contains("x64") || name.contains("amd64") || name.contains("intel")
        case .intel:
            return name.contains("arm64") || name.contains("aarch64") || name.contains("apple-silicon")
        }
    }

    private static func defaultProbeDownload(_ url: URL) throws -> String {
        var request = URLRequest(url: url)
        request.httpMethod = "HEAD"
        request.timeoutInterval = 60

        let semaphore = DispatchSemaphore(value: 0)
        var result: Result<String, Error>!
        URLSession.shared.dataTask(with: request) { _, response, error in
            defer { semaphore.signal() }
            if let error {
                result = .failure(error)
                return
            }
            guard let response = response as? HTTPURLResponse else {
                result = .failure(UpdateRecipeProbeError.missingHTTPResponse)
                return
            }
            guard (200...399).contains(response.statusCode) else {
                result = .failure(UpdateRecipeProbeError.httpStatus(response.statusCode))
                return
            }

            let finalURL = response.url ?? url
            guard PackageURLParser.isPackageURL(url) || PackageURLParser.isPackageURL(finalURL) else {
                result = .failure(UpdateRecipeProbeError.redirectedToNonPackage(finalURL))
                return
            }
            if response.mimeType?.lowercased() == "text/html" {
                result = .failure(UpdateRecipeProbeError.unexpectedContentType("text/html"))
                return
            }

            let size = response.expectedContentLength > 0
                ? ByteCountFormatter.string(fromByteCount: response.expectedContentLength, countStyle: .file)
                : nil
            let details = [
                "HTTP \(response.statusCode)",
                size.map { "大小 \($0)" },
                finalURL == url ? nil : "已跟随重定向",
            ].compactMap { $0 }
            result = .success(details.joined(separator: "，"))
        }.resume()
        semaphore.wait()
        return try result.get()
    }
}

private enum UpdateRecipeProbeError: LocalizedError {
    case missingHTTPResponse
    case httpStatus(Int)
    case redirectedToNonPackage(URL)
    case unexpectedContentType(String)

    var errorDescription: String? {
        switch self {
        case .missingHTTPResponse:
            return "没有收到 HTTP 响应"
        case let .httpStatus(statusCode):
            return "HTTP \(statusCode)"
        case let .redirectedToNonPackage(url):
            return "最终地址不是安装包：\(url.absoluteString)"
        case let .unexpectedContentType(contentType):
            return "响应内容类型不正确：\(contentType)"
        }
    }
}
