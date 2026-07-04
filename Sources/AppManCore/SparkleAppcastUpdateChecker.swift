import Foundation

public struct SparkleAppcastUpdateChecker: AppUpdateChecking {
    private let fetchData: @Sendable (URL) throws -> Data

    public init(fetchData: @escaping @Sendable (URL) throws -> Data = { url in
        try Data(contentsOf: url)
    }) {
        self.fetchData = fetchData
    }

    public func checkUpdates(for apps: [AppRecord]) throws -> [AppRecord] {
        try LimitedConcurrentMap.map(apps, limit: 3) { app in
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

        do {
            let data = try fetchData(feedURL)
            guard let latestVersion = SparkleAppcastParser.parseLatestVersion(from: data) else {
                updatedApp.updateStatus = .checkFailed(message: "Sparkle appcast 中没有版本信息")
                return updatedApp
            }

            if AppVersionComparator.isLatestVersion(latestVersion, newerThan: app.shortVersion) {
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

private final class SparkleAppcastParser: NSObject, XMLParserDelegate {
    private var shortVersions: [String] = []
    private var buildVersions: [String] = []
    private var capturedText = ""
    private var isInsideItem = false

    static func parseLatestVersion(from data: Data) -> String? {
        let delegate = SparkleAppcastParser()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        guard parser.parse() else {
            return nil
        }
        return delegate.latestVersion
    }

    private var latestVersion: String? {
        maxVersion(in: shortVersions) ?? maxVersion(in: buildVersions)
    }

    private func maxVersion(in versions: [String]) -> String? {
        versions.max { first, second in
            first.compare(second, options: .numeric) == .orderedAscending
        }
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
        }

        guard isInsideItem else {
            return
        }

        if let shortVersion = sparkleValue(named: "shortVersionString", in: attributeDict) {
            shortVersions.append(shortVersion)
        } else if let buildVersion = sparkleValue(named: "version", in: attributeDict) {
            buildVersions.append(buildVersion)
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
            isInsideItem = false
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

        if name.hasSuffix("shortVersionString") {
            shortVersions.append(value)
        } else if name.hasSuffix("version") {
            buildVersions.append(value)
        }
    }

    private func sparkleValue(named suffix: String, in attributes: [String: String]) -> String? {
        for (key, value) in attributes where key.hasSuffix(suffix) && !value.isEmpty {
            return value
        }
        return nil
    }
}
