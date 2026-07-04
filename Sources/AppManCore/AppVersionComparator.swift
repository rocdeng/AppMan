import Foundation

enum AppVersionComparator {
    static func isLatestVersion(_ latestVersion: String, newerThan installedVersion: String?) -> Bool {
        guard let installedVersion, !installedVersion.isEmpty else {
            return true
        }

        return latestVersion.compare(installedVersion, options: .numeric) == .orderedDescending
    }
}
