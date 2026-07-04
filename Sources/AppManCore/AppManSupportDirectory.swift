import Foundation

enum AppManSupportDirectory {
    static func url() -> URL {
        let baseURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first ?? FileManager.default.homeDirectoryForCurrentUser
        return baseURL.appendingPathComponent("AppMan", isDirectory: true)
    }
}
