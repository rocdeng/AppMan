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

    init(
        scanner: AppScanner = AppScanner(),
        installSourceResolver: InstallSourceResolver = InstallSourceResolver(),
        updateChecker: any AppUpdateChecking = HomebrewCaskUpdateChecker()
    ) {
        self.scanner = scanner
        self.installSourceResolver = installSourceResolver
        self.updateChecker = updateChecker
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
            let resolvedApps = try await Task.detached(priority: .userInitiated) {
                let apps = try scanner.scanInstalledApps()
                return try installSourceResolver.resolveInstallSources(for: apps)
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
            let currentApps = apps
            let updatedApps = try await Task.detached(priority: .userInitiated) {
                try updateChecker.checkUpdates(for: currentApps)
            }.value

            apps = updatedApps
        } catch {
            errorMessage = error.localizedDescription
        }

        isCheckingUpdates = false
    }
}
