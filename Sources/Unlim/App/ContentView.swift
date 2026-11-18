import SwiftUI

/// Root view: login flow until TDLib reports authorizationStateReady,
/// then the main tabs.
struct ContentView: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        if appState.auth.state == .ready {
            TabView {
                TopicsView()
                    .tabItem { Label("Saved Messages", systemImage: "tray.full") }
                QueueView()
                    .tabItem { Label("Queue", systemImage: "arrow.up.circle") }
                SettingsView()
                    .tabItem { Label("Settings", systemImage: "gear") }
            }
        } else {
            LoginView()
        }
    }
}
