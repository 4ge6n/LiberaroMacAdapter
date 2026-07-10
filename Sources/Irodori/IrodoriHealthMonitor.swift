import Foundation

enum IrodoriHealthStatus: Equatable, Sendable {
    case unknown
    case healthy
    case unreachable(String)
}

/// `GET /health` を軽くポーリングして、subprocess が本当に listen しているかを確認する。
@MainActor
final class IrodoriHealthMonitor: ObservableObject {
    @Published private(set) var status: IrodoriHealthStatus = .unknown
    private var task: Task<Void, Never>?

    func start(port: UInt16, token: String) {
        stop()
        task = Task { [weak self] in
            while !Task.isCancelled {
                await self?.probe(port: port, token: token)
                try? await Task.sleep(nanoseconds: 3_000_000_000)
            }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
        status = .unknown
    }

    private func probe(port: UInt16, token: String) async {
        guard let url = URL(string: "http://127.0.0.1:\(port)/health") else { return }
        var request = URLRequest(url: url)
        request.timeoutInterval = 3
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue(token, forHTTPHeaderField: "X-Liberaro-Token")
        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                status = .unreachable("invalid response")
                return
            }
            status = (200..<300).contains(http.statusCode) ? .healthy : .unreachable("HTTP \(http.statusCode)")
        } catch {
            status = .unreachable(String(describing: error))
        }
    }
}
