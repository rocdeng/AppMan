import AppManCore
import SwiftUI

@main
struct AppManApp: App {
    init() {
        if CommandLine.arguments.contains("--smoke-scan") {
            do {
                let apps = try InstallSourceResolver()
                    .resolveInstallSources(for: AppScanner().scanInstalledApps())
                print("APP_MAN_SMOKE_SCAN_COUNT=\(apps.count)")
                exit(0)
            } catch {
                fputs("APP_MAN_SMOKE_SCAN_ERROR=\(error)\n", stderr)
                exit(1)
            }
        }
    }

    var body: some Scene {
        WindowGroup {
            AppListView()
                .frame(minWidth: 900, minHeight: 560)
        }
    }
}
