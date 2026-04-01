import SwiftUI

@main
struct Test_AutomatitacionApp: App {
    @State private var appState = AppState()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(appState)
                .preferredColorScheme(appState.profile.prefersDarkMode ? .dark : nil)
        }
    }
}
