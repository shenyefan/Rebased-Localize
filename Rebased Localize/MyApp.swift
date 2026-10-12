import SwiftUI

@main
struct RebasedLocalizeApp: App {
    @NSApplicationDelegateAdaptor(ApplicationDelegate.self) private var applicationDelegate
    var body: some Scene {
        Window("Rebased Localize", id: "main") {
            ContentView()
                .background(FixedWindowConfiguration())
        }
        .defaultSize(width: 820, height: 760)
        .windowResizability(.contentSize)
        .commandsRemoved()
    }
}
