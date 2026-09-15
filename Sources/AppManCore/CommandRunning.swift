import Foundation

public protocol CommandRunning: Sendable {
    func run(_ executable: String, arguments: [String]) throws -> String
}

public enum CommandError: LocalizedError, Equatable {
    case executableNotFound(String)
    case failed(status: Int32, stderr: String)
    case timedOut(String)

    public var errorDescription: String? {
        switch self {
        case let .executableNotFound(executable):
            return "找不到命令：\(executable)"
        case let .failed(status, stderr):
            let detail = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            return detail.isEmpty ? "命令执行失败（退出码 \(status)）" : detail
        case let .timedOut(executable):
            return "命令执行超时：\(executable)"
        }
    }
}

public struct ProcessCommandRunner: CommandRunning {
    private let searchDirectories: [URL]
    private let environment: [String: String]
    private let timeout: TimeInterval?

    public init(
        searchDirectories: [URL]? = nil,
        environment: [String: String] = [:],
        timeout: TimeInterval? = nil
    ) {
        self.searchDirectories = searchDirectories ?? Self.defaultSearchDirectories
        self.environment = environment
        self.timeout = timeout
    }

    public func run(_ executable: String, arguments: [String]) throws -> String {
        guard let executableURL = findExecutable(named: executable) else {
            throw CommandError.executableNotFound(executable)
        }

        let process = Process()
        process.executableURL = executableURL
        process.arguments = arguments
        if !environment.isEmpty {
            process.environment = ProcessInfo.processInfo.environment.merging(environment) { _, override in override }
        }

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        try process.run()
        let readGroup = DispatchGroup()
        var stdoutData = Data()
        var stderrData = Data()

        readGroup.enter()
        DispatchQueue.global(qos: .utility).async {
            stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
            readGroup.leave()
        }

        readGroup.enter()
        DispatchQueue.global(qos: .utility).async {
            stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
            readGroup.leave()
        }

        if let timeout {
            let didExit = DispatchSemaphore(value: 0)
            process.terminationHandler = { _ in didExit.signal() }
            guard didExit.wait(timeout: .now() + timeout) == .success else {
                process.terminate()
                process.waitUntilExit()
                readGroup.wait()
                throw CommandError.timedOut(executable)
            }
        } else {
            process.waitUntilExit()
        }
        readGroup.wait()

        let stdout = String(data: stdoutData, encoding: .utf8) ?? ""
        let stderr = String(data: stderrData, encoding: .utf8) ?? ""

        guard process.terminationStatus == 0 else {
            throw CommandError.failed(status: process.terminationStatus, stderr: stderr)
        }

        return stdout
    }

    private func findExecutable(named executable: String) -> URL? {
        for directory in searchDirectories {
            let url = directory.appendingPathComponent(executable)
            if FileManager.default.isExecutableFile(atPath: url.path) {
                return url
            }
        }
        return nil
    }

    private static let defaultSearchDirectories = [
        URL(fileURLWithPath: "/opt/homebrew/bin", isDirectory: true),
        URL(fileURLWithPath: "/usr/local/bin", isDirectory: true),
        URL(fileURLWithPath: "/usr/bin", isDirectory: true),
        URL(fileURLWithPath: "/bin", isDirectory: true),
    ]
}
