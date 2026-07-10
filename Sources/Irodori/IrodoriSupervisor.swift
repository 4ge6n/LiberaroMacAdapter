import Foundation
import os.log

enum IrodoriSupervisorState: Equatable, Sendable {
    case stopped
    case starting
    case running(port: UInt16)
    case failed(String)
}

/// `irodori_batch_server.py`（アプリバンドルに同梱、stdlib のみで動く）を
/// subprocess として起動/停止し、ログを保持する。
///
/// この Python サーバ自体はネイティブ再実装せず既存実装をそのまま使う。
/// ローカルで動く Gradio (Irodori) との橋渡しプロトコルは未検証環境で
/// 書き直すリスクが高いため、Adapter 側は「起動/停止/死活監視/ログ」の
/// 管理層に徹する。
@MainActor
final class IrodoriSupervisor: ObservableObject {
    private let log = Logger(subsystem: "com.4ge6n.LiberaroMacAdapter", category: "irodori.supervisor")

    @Published private(set) var state: IrodoriSupervisorState = .stopped
    @Published private(set) var logLines: [String] = []

    private var process: Process?
    private let scriptURL: URL
    private let jobRoot: URL
    let token: String
    private var healthTimer: Timer?

    init(scriptURL: URL, jobRoot: URL, token: String) {
        self.scriptURL = scriptURL
        self.jobRoot = jobRoot
        self.token = token
    }

    func start(host: String = "0.0.0.0", port: UInt16) {
        guard case .stopped = state else { return }
        state = .starting
        appendLog("starting irodori_batch_server.py on \(host):\(port)")

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = [
            scriptURL.path,
            "--host", host,
            "--port", String(port),
            "--token", token,
        ]
        var env = ProcessInfo.processInfo.environment
        env["IRODORI_BATCH_JOB_ROOT"] = jobRoot.path
        process.environment = env

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
            Task { @MainActor in
                self?.appendLog(text)
            }
        }
        process.terminationHandler = { [weak self] proc in
            Task { @MainActor in
                self?.handleTermination(status: proc.terminationStatus)
            }
        }

        do {
            try process.run()
            self.process = process
            self.state = .running(port: port)
            appendLog("running (pid \(process.processIdentifier))")
        } catch {
            state = .failed(String(describing: error))
            appendLog("failed to launch: \(error)")
        }
    }

    func stop() {
        guard let process, process.isRunning else {
            state = .stopped
            return
        }
        appendLog("stopping (pid \(process.processIdentifier))")
        process.terminate()
    }

    private func handleTermination(status: Int32) {
        appendLog("process exited (status \(status))")
        process = nil
        state = .stopped
    }

    private func appendLog(_ text: String) {
        let lines = text.split(separator: "\n").map(String.init)
        logLines.append(contentsOf: lines)
        if logLines.count > 500 {
            logLines.removeFirst(logLines.count - 500)
        }
        log.debug("\(text, privacy: .public)")
    }

    var isRunning: Bool {
        if case .running = state { return true }
        return false
    }
}
