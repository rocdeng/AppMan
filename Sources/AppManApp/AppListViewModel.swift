import AppManCore
import Foundation

@MainActor
final class AppListViewModel: ObservableObject {
    @Published private(set) var apps: [AppRecord] = []
    @Published private(set) var isScanning = false
    @Published var errorMessage: String?

    private let scanner: AppScanner
    private let installSourceResolver: InstallSourceResolver

    init(
        scanner: AppScanner = AppScanner(),
        installSourceResolver: InstallSourceResolver = InstallSourceResolver()
    ) {
        self.scanner = scanner
        self.installSourceResolver = installSourceResolver
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
}
