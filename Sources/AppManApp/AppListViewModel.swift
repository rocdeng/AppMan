import AppManCore
import Foundation

@MainActor
final class AppListViewModel: ObservableObject {
    @Published private(set) var apps: [AppRecord] = []
    @Published private(set) var isScanning = false
    @Published private(set) var isCheckingUpdates = false
    @Published var errorMessage: String?

    private let scanner: AppScanner
    private let installSourceResolver: InstallSourceResolver
    private let updateChecker: any AppUpdateChecking
    private let appCache: AppRecordCache

    init(
        scanner: AppScanner = AppScanner(),
        installSourceResolver: InstallSourceResolver = InstallSourceResolver(),
        updateChecker: any AppUpdateChecking = HomebrewCaskUpdateChecker(),
        appCache: AppRecordCache = AppRecordCache()
    ) {
        self.scanner = scanner
        self.installSourceResolver = installSourceResolver
        self.updateChecker = updateChecker
        self.appCache = appCache
        apps = (try? appCache.load()) ?? []
    }

    func scan() async {
        guard !isScanning else {
            return
        }

        isScanning = true
        errorMessage = nil

        do {
            let scanner = self.scanner
            let installSourceResolver = self.installSourceResolver
            let appCache = self.appCache
            let resolvedApps = try await Task.detached(priority: .userInitiated) {
                let apps = try scanner.scanInstalledApps()
                let resolvedApps = try installSourceResolver.resolveInstallSources(for: apps)
                try appCache.save(resolvedApps)
                return resolvedApps
            }.value

            apps = resolvedApps
        } catch {
            errorMessage = error.localizedDescription
        }

        isScanning = false
    }

    func checkUpdates() async {
        guard !isCheckingUpdates else {
            return
        }

        isCheckingUpdates = true
        errorMessage = nil

        do {
            let updateChecker = self.updateChecker
            let appCache = self.appCache
            let currentApps = apps
            let updatedApps = try await Task.detached(priority: .userInitiated) {
                let updatedApps = try updateChecker.checkUpdates(for: currentApps)
                try appCache.save(updatedApps)
                return updatedApps
            }.value

            apps = updatedApps
        } catch {
            errorMessage = error.localizedDescription
        }

        isCheckingUpdates = false
    }
}
