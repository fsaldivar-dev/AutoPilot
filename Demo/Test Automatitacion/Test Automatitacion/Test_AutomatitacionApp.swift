import SwiftUI
import AutoPilotAVFoundation

@main
struct Test_AutomatitacionApp: App {
    @State private var appState = AppState()

    init() {
        AutoPilotCamera.activate()
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(appState)
                .preferredColorScheme(appState.profile.prefersDarkMode ? .dark : nil)
        }
    }
}
