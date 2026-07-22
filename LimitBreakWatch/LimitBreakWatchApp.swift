import SwiftUI

@main
struct LimitBreakWatchApp: App {
    @State private var store = WatchSessionStore()

    var body: some Scene {
        WindowGroup {
            WatchRootView()
                .environment(store)
        }
    }
}
