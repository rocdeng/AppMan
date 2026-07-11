import Foundation

public struct UninstallCandidate: Identifiable, Equatable, Sendable {
    public let id: String
    public let url: URL
    public let name: String
    public let kind: UninstallCandidateKind
    public let sizeBytes: Int64
    public let isRequired: Bool

    public init(
        url: URL,
        name: String,
        kind: UninstallCandidateKind,
        sizeBytes: Int64,
        isRequired: Bool = false
    ) {
        self.id = url.standardizedFileURL.path
        self.url = url
        self.name = name
        self.kind = kind
        self.sizeBytes = sizeBytes
        self.isRequired = isRequired
    }
}

public enum UninstallCandidateKind: String, Equatable, Sendable {
    case application
    case applicationSupport
    case cache
    case preferences
    case applicationScript
    case container
    case groupContainer
    case log
    case savedState
    case installer
    case other

    public var displayName: String {
        switch self {
        case .application:
            return "应用程序"
        case .applicationSupport:
            return "应用数据"
        case .cache:
            return "缓存"
        case .preferences:
            return "配置"
        case .applicationScript:
            return "应用脚本"
        case .container:
            return "容器数据"
        case .groupContainer:
            return "共享容器"
        case .log:
            return "日志"
        case .savedState:
            return "窗口状态"
        case .installer:
            return "安装包"
        case .other:
            return "关联文件"
        }
    }
}

public struct UninstallCandidateFinder: Sendable {
    private let libraryDirectory: URL
    private let downloadsDirectory: URL?

    public init(
        libraryDirectory: URL? = nil,
        downloadsDirectory: URL? = nil
    ) {
        let fileManager = FileManager.default
        self.libraryDirectory = libraryDirectory
            ?? fileManager.urls(for: .libraryDirectory, in: .userDomainMask).first
            ?? fileManager.homeDirectoryForCurrentUser.appendingPathComponent("Library", isDirectory: true)
        self.downloadsDirectory = downloadsDirectory
            ?? fileManager.urls(for: .downloadsDirectory, in: .userDomainMask).first
    }

    public func findCandidates(for app: AppRecord) throws -> [UninstallCandidate] {
        let names = searchNames(for: app)
        let bundleIdentifier = app.bundleIdentifier?.trimmingCharacters(in: .whitespacesAndNewlines)
        var candidates: [UninstallCandidate] = []
        var seenPaths = Set<String>()

        appendCandidate(
            at: app.path,
            name: app.name,
            kind: .application,
            isRequired: true,
            candidates: &candidates,
            seenPaths: &seenPaths
        )

        appendMatchingChildren(
            in: libraryDirectory.appendingPathComponent("Application Support", isDirectory: true),
            matching: names + [bundleIdentifier].compactMap { $0 },
            kind: .applicationSupport,
            candidates: &candidates,
            seenPaths: &seenPaths
        )
        appendMatchingChildren(
            in: libraryDirectory.appendingPathComponent("Caches", isDirectory: true),
            matching: names + [bundleIdentifier].compactMap { $0 },
            kind: .cache,
            candidates: &candidates,
            seenPaths: &seenPaths
        )
        if let bundleIdentifier, !bundleIdentifier.isEmpty {
            appendCandidate(
                at: libraryDirectory.appendingPathComponent("Application Scripts/\(bundleIdentifier)", isDirectory: true),
                name: bundleIdentifier,
                kind: .applicationScript,
                candidates: &candidates,
                seenPaths: &seenPaths
            )
        }
        appendMatchingChildren(
            in: libraryDirectory.appendingPathComponent("Containers", isDirectory: true),
            matching: names + [bundleIdentifier].compactMap { $0 },
            kind: .container,
            candidates: &candidates,
            seenPaths: &seenPaths
        )
        if let bundleIdentifier, !bundleIdentifier.isEmpty {
            appendMatchingChildren(
                in: libraryDirectory.appendingPathComponent("Group Containers", isDirectory: true),
                matching: [bundleIdentifier],
                kind: .groupContainer,
                candidates: &candidates,
                seenPaths: &seenPaths
            )
        }
        appendMatchingChildren(
            in: libraryDirectory.appendingPathComponent("Logs", isDirectory: true),
            matching: names + [bundleIdentifier].compactMap { $0 },
            kind: .log,
            candidates: &candidates,
            seenPaths: &seenPaths
        )

        if let bundleIdentifier, !bundleIdentifier.isEmpty {
            appendCandidate(
                at: libraryDirectory.appendingPathComponent("Preferences/\(bundleIdentifier).plist"),
                name: "\(bundleIdentifier).plist",
                kind: .preferences,
                candidates: &candidates,
                seenPaths: &seenPaths
            )
            appendCandidate(
                at: libraryDirectory.appendingPathComponent("Saved Application State/\(bundleIdentifier).savedState", isDirectory: true),
                name: "\(bundleIdentifier).savedState",
                kind: .savedState,
                candidates: &candidates,
                seenPaths: &seenPaths
            )
        }

        if let downloadsDirectory {
            appendInstallers(
                in: downloadsDirectory,
                matching: names + [bundleIdentifier].compactMap { $0 },
                candidates: &candidates,
                seenPaths: &seenPaths
            )
        }

        return candidates
    }

    private func searchNames(for app: AppRecord) -> [String] {
        var values = [app.name]
        values.append(app.path.deletingPathExtension().lastPathComponent)
        return Array(Set(values.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }))
    }

    private func appendMatchingChildren(
        in directory: URL,
        matching names: [String],
        kind: UninstallCandidateKind,
        candidates: inout [UninstallCandidate],
        seenPaths: inout Set<String>
    ) {
        let fileManager = FileManager.default
        guard let children = try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else {
            return
        }

        for child in children where matches(child.lastPathComponent, names: names) {
            appendCandidate(
                at: child,
                name: child.lastPathComponent,
                kind: kind,
                candidates: &candidates,
                seenPaths: &seenPaths
            )
        }
    }

    private func appendInstallers(
        in directory: URL,
        matching names: [String],
        candidates: inout [UninstallCandidate],
        seenPaths: inout Set<String>
    ) {
        let fileManager = FileManager.default
        guard let children = try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else {
            return
        }

        let installerExtensions: Set<String> = ["dmg", "pkg", "zip"]
        for child in children {
            let fileExtension = child.pathExtension.localizedLowercase
            guard installerExtensions.contains(fileExtension),
                  matches(child.deletingPathExtension().lastPathComponent, names: names) else {
                continue
            }

            appendCandidate(
                at: child,
                name: child.lastPathComponent,
                kind: .installer,
                candidates: &candidates,
                seenPaths: &seenPaths
            )
        }
    }

    private func appendCandidate(
        at url: URL,
        name: String,
        kind: UninstallCandidateKind,
        isRequired: Bool = false,
        candidates: inout [UninstallCandidate],
        seenPaths: inout Set<String>
    ) {
        let fileManager = FileManager.default
        let path = url.standardizedFileURL.path
        guard !seenPaths.contains(path), fileManager.fileExists(atPath: path) else {
            return
        }

        seenPaths.insert(path)
        candidates.append(UninstallCandidate(
            url: url,
            name: name,
            kind: kind,
            sizeBytes: sizeOfItem(at: url),
            isRequired: isRequired
        ))
    }

    private func matches(_ value: String, names: [String]) -> Bool {
        let normalizedValue = value.localizedLowercase
        return names.contains { name in
            let normalizedName = name.localizedLowercase
            return normalizedValue == normalizedName
                || normalizedValue.contains(normalizedName)
                || normalizedName.contains(normalizedValue)
        }
    }

    private func sizeOfItem(at url: URL) -> Int64 {
        let fileManager = FileManager.default
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
            return 0
        }

        if !isDirectory.boolValue {
            let attributes = try? fileManager.attributesOfItem(atPath: url.path)
            return attributes?[.size] as? Int64 ?? 0
        }

        guard let enumerator = fileManager.enumerator(
            at: url,
            includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return 0
        }

        var total: Int64 = 0
        for case let fileURL as URL in enumerator {
            let values = try? fileURL.resourceValues(forKeys: [
                .fileSizeKey,
                .isRegularFileKey,
            ])
            guard values?.isRegularFile == true else {
                continue
            }
            total += Int64(values?.fileSize ?? 0)
        }

        return total
    }
}
