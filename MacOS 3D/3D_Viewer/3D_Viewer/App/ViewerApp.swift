import SwiftUI

@main
struct ViewerApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .windowResizability(.contentSize)
        .defaultSize(width: 1200, height: 800)
    }
}
