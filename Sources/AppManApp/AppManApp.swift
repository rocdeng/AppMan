import SwiftUI

@main
struct AppManApp: App {
    var body: some Scene {
        WindowGroup {
            AppListView()
                .frame(minWidth: 900, minHeight: 560)
        }
    }
}
