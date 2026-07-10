import SwiftUI

struct PairingView: View {
    @EnvironmentObject private var appState: AppState
    @State private var payloadText: String = ""
    @State private var qrImage: NSImage?
    @State private var errorMessage: String?

    var body: some View {
        VStack(spacing: 16) {
            Text("iOS アプリの設定画面でこの QR コードを読み取ると、LAN アドレス・ポート・認証トークンが自動入力されます。")
                .font(.callout)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .padding(.horizontal)

            if let qrImage {
                Image(nsImage: qrImage)
                    .interpolation(.none)
                    .resizable()
                    .frame(width: 260, height: 260)
                    .padding()
                    .background(.white, in: RoundedRectangle(cornerRadius: 12))
                    .shadow(radius: 2)
            } else if let errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
            } else {
                ProgressView()
            }

            VStack(alignment: .leading, spacing: 4) {
                LabeledContent("Upscale") {
                    Text("\(hostText):\(appState.upscalePort)")
                        .textSelection(.enabled)
                        .font(.system(.body, design: .monospaced))
                }
                LabeledContent("Irodori TTS") {
                    Text("\(hostText):\(appState.irodoriPort)")
                        .textSelection(.enabled)
                        .font(.system(.body, design: .monospaced))
                }
            }
            .font(.caption)
            .padding(.horizontal)

            Button("再生成") { regenerate() }
                .buttonStyle(.bordered)
        }
        .padding()
        .onAppear(perform: regenerate)
    }

    private var hostText: String {
        NetworkInfo.primaryLANAddress() ?? "?"
    }

    private func regenerate() {
        guard let payload = appState.pairingPayload() else {
            errorMessage = "LAN アドレスを取得できませんでした（Wi-Fi 接続を確認してください）"
            qrImage = nil
            return
        }
        do {
            let text = try payload.encodedString()
            payloadText = text
            qrImage = QRCodeGenerator.image(for: text)
            errorMessage = qrImage == nil ? "QR コードの生成に失敗しました" : nil
        } catch {
            errorMessage = "エンコードに失敗しました: \(error)"
            qrImage = nil
        }
    }
}

#Preview {
    PairingView().environmentObject(AppState())
}
