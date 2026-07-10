import SwiftUI

struct ContentView: View {
    var body: some View {
        TabView {
            UpscalePanelView()
                .tabItem { Label("Upscale", systemImage: "wand.and.stars") }
            IrodoriPanelView()
                .tabItem { Label("Irodori TTS", systemImage: "waveform") }
            PairingView()
                .tabItem { Label("ペアリング", systemImage: "qrcode") }
        }
        .frame(minWidth: 560, minHeight: 460)
    }
}

#Preview {
    ContentView().environmentObject(AppState())
}
