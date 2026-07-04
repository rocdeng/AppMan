import Foundation

public struct UpdateRecipe: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public let name: String
    public let recipePrompt: String?
    public let match: Match
    public let checks: [Check]
    public let updatePageURL: URL?

    public init(
        id: String,
        name: String,
        recipePrompt: String?,
        match: Match,
        checks: [Check],
        updatePageURL: URL?
    ) {
        self.id = id
        self.name = name
        self.recipePrompt = recipePrompt
        self.match = match
        self.checks = checks
        self.updatePageURL = updatePageURL
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

    init(fetchData: @escaping @Sendable (URL) throws -> Data) {
        self.fetchData = fetchData
    }

    func latestVersion(using recipe: UpdateRecipe) throws -> String? {
        var versions: [String] = []

        for check in recipe.checks {
            let data = try fetchData(check.url)
            guard let text = String(data: data, encoding: .utf8) else {
                continue
            }
            versions.append(contentsOf: extractVersions(from: text, using: check.extract))
        }

        return versions.max { first, second in
            first.compare(second, options: .numeric) == .orderedAscending
        }
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
