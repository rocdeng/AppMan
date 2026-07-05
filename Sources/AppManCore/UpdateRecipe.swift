import Foundation

public struct UpdateRecipe: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public let name: String
    public let recipePrompt: String?
    public let match: Match
    public let checks: [Check]
    public let updatePageURL: URL?
    public let download: Download?

    public init(
        id: String,
        name: String,
        recipePrompt: String?,
        match: Match,
        checks: [Check],
        updatePageURL: URL?,
        download: Download? = nil
    ) {
        self.id = id
        self.name = name
        self.recipePrompt = recipePrompt
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

    public struct Download: Codable, Equatable, Sendable {
        public let url: URL?
        public let sourceURL: URL?
        public let pattern: String?
        public let urlGroup: Int?

        public init(url: URL?, sourceURL: URL?, pattern: String?, urlGroup: Int?) {
            self.url = url
            self.sourceURL = sourceURL
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

        guard let sourceURL = download.sourceURL,
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

        if let matched = candidates.first(where: { candidate in
            let path = candidate.lastPathComponent.lowercased()
            return versionForms.contains { path.contains($0) }
        }) {
            return matched
        }

        return candidates.first
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
