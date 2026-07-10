import SwiftUI

struct IrodoriPanelView: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Circle()
                    .fill(statusColor)
                    .frame(width: 10, height: 10)
                Text(statusLabel)
                    .font(.headline)
                Spacer()
                Button(appState.irodoriSupervisor.isRunning ? "停止" : "起動") {
                    if appState.irodoriSupervisor.isRunning {
                        appState.stopIrodoriService()
                    } else {
                        appState.startIrodoriService()
                    }
                }
            }

            Text(
                "ローカルの Irodori (Gradio) サーバが起動している状態で使ってください。"
                + "このアダプタは irodori_batch_server.py をサブプロセスとして起動/監視するだけで、"
                + "Gradio との橋渡しプロトコル自体は既存実装をそのまま使います。"
            )
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)

            Divider()

            Text("ログ")
                .font(.subheadline.weight(.semibold))
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(Array(appState.irodoriSupervisor.logLines.enumerated()), id: \.offset) { index, line in
                            Text(line)
                                .font(.system(.caption2, design: .monospaced))
                                .id(index)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .onChange(of: appState.irodoriSupervisor.logLines.count) { _, _ in
                    if let last = appState.irodoriSupervisor.logLines.indices.last {
                        proxy.scrollTo(last, anchor: .bottom)
                    }
                }
            }
            .background(.black.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
        }
        .padding()
    }

    private var statusColor: Color {
        switch appState.irodoriHealth.status {
        case .healthy: return .green
        case .unreachable: return appState.irodoriSupervisor.isRunning ? .orange : .red
        case .unknown: return appState.irodoriSupervisor.isRunning ? .orange : .red
        }
    }

    private var statusLabel: String {
        if !appState.irodoriSupervisor.isRunning {
            return "停止中"
        }
        switch appState.irodoriHealth.status {
        case .healthy: return "稼働中 · ポート \(appState.irodoriPort)（応答あり）"
        case .unreachable(let reason): return "起動中だが応答なし (\(reason))"
        case .unknown: return "起動中 · 応答確認中…"
        }
    }
}

#Preview {
    IrodoriPanelView().environmentObject(AppState())
}
