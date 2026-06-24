import Foundation

public protocol CommandRunning: Sendable {
    func run(_ executable: String, arguments: [String]) throws -> String
}

public enum CommandError: Error, Equatable {
    case executableNotFound(String)
    case failed(status: Int32, stderr: String)
}

public struct ProcessCommandRunner: CommandRunning {
    private let searchDirectories: [URL]

    public init(searchDirectories: [URL]? = nil) {
        self.searchDirectories = searchDirectories ?? Self.defaultSearchDirectories
    }

    public func run(_ executable: String, arguments: [String]) throws -> String {
        guard let executableURL = findExecutable(named: executable) else {
            throw CommandError.executableNotFound(executable)
        }

        let process = Process()
        process.executableURL = executableURL
        process.arguments = arguments

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

        process.waitUntilExit()
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
