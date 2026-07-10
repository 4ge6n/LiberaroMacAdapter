import SwiftUI

@main
struct LiberaroMacAdapterApp: App {
    @StateObject private var appState = AppState()
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(appState)
                .onAppear {
                    appDelegate.appState = appState
                    appState.startUpscaleService()
                    appState.startIrodoriService()
                }
        }
        .windowResizability(.contentSize)
    }
}
