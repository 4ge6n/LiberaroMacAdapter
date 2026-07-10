import SwiftUI

struct UpscalePanelView: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Circle()
                    .fill(appState.upscaleRunning ? .green : .red)
                    .frame(width: 10, height: 10)
                Text(appState.upscaleRunning ? "稼働中 · ポート \(appState.upscalePort)" : "停止中")
                    .font(.headline)
                Spacer()
                Button(appState.upscaleRunning ? "停止" : "起動") {
                    if appState.upscaleRunning {
                        appState.stopUpscaleService()
                    } else {
                        appState.startUpscaleService()
                    }
                }
            }
            if let error = appState.upscaleStartError {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                    .font(.caption)
            }

            progressSummary

            Divider()

            Text("ジョブキュー")
                .font(.subheadline.weight(.semibold))
            if appState.jobs.isEmpty {
                ContentUnavailableView(
                    "ジョブはありません",
                    systemImage: "tray",
                    description: Text("iOS から投入されたアップスケールジョブがここに表示されます。")
                )
            } else {
                List(appState.jobs, id: \.id) { job in
                    HStack {
                        statusIcon(for: job.status)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("\(job.engine) · \(job.modelID.isEmpty ? "(既定)" : job.modelID)")
                                .font(.body)
                            Text("scale=\(job.scale) noise=\(job.noise) · \(job.id.prefix(8))")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            if let error = job.error {
                                Text(error)
                                    .font(.caption2)
                                    .foregroundStyle(.red)
                                    .lineLimit(2)
                            }
                        }
                        Spacer()
                        Text(job.status.rawValue)
                            .font(.caption.weight(.semibold))
                    }
                }
            }
        }
        .padding()
    }

    private var progressSummary: some View {
        HStack(spacing: 16) {
            statTile("合計", appState.progress.total)
            statTile("残り", appState.progress.remaining)
            statTile("完了", appState.progress.done)
            statTile("失敗", appState.progress.failed)
        }
    }

    private func statTile(_ label: String, _ value: Int) -> some View {
        VStack {
            Text("\(value)").font(.title3.weight(.bold))
            Text(label).font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
    }

    @ViewBuilder
    private func statusIcon(for status: UpscaleJobStatus) -> some View {
        switch status {
        case .queued:
            Image(systemName: "clock").foregroundStyle(.secondary)
        case .processing:
            Image(systemName: "gearshape.fill").foregroundStyle(.blue)
        case .done:
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .failed:
            Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
        case .cancelled:
            Image(systemName: "minus.circle.fill").foregroundStyle(.secondary)
        }
    }
}

#Preview {
    UpscalePanelView().environmentObject(AppState())
}
