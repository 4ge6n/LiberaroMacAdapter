import AppKit

/// アプリ終了時に irodori_batch_server.py の subprocess を確実に止める。
/// SwiftUI の `.onDisappear` は Cmd+Q / Dock 終了では呼ばれないため、
/// `NSApplicationDelegate` の `applicationWillTerminate` を使う。
final class AppDelegate: NSObject, NSApplicationDelegate {
    var appState: AppState?

    func applicationWillTerminate(_ notification: Notification) {
        appState?.stopIrodoriService()
        appState?.stopUpscaleService()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}
