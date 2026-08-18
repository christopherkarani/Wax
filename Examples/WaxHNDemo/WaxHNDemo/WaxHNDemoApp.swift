import SwiftUI

@main
struct WaxHNDemoApp: App {
    var body: some Scene {
        WindowGroup {
            SearchScreen()
        }
        #if os(macOS)
        .defaultSize(width: 720, height: 560)
        #endif
    }
}
