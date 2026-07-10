import Foundation
import Network
import os.log

/// 依存ゼロの最小 HTTP/1.1 サーバー。Python 版サイドカー (`http.server.ThreadingHTTPServer`)
/// と同じく、リクエストごとに `Connection: close` で完結させる（keep-alive/pipelining は未対応）。
/// GET/POST/DELETE + `Content-Length` ボディのみを扱う。chunked transfer-encoding は非対応
/// （iOS クライアントも使わない）。
final class MiniHTTPServer: @unchecked Sendable {
    private let log = Logger(subsystem: "com.4ge6n.LiberaroMacAdapter", category: "http")
    private let queue = DispatchQueue(label: "MiniHTTPServer.listener")
    private var listener: NWListener?
    /// `NWConnection` の receive クロージャは `self` を弱参照するだけなので、
    /// どこかで強参照を持たないと `accept()` を抜けた瞬間に ARC で解放され、
    /// 以後のコールバックが `guard let self` で無言スキップされて応答が返らなくなる。
    private var activeConnections: [ObjectIdentifier: MiniHTTPConnection] = [:]

    private(set) var port: UInt16 = 0
    let maxBodyBytes: Int
    let handler: (HTTPRequest) async -> HTTPResponse

    init(maxBodyBytes: Int = 100 * 1024 * 1024, handler: @escaping (HTTPRequest) async -> HTTPResponse) {
        self.maxBodyBytes = maxBodyBytes
        self.handler = handler
    }

    /// 指定ポートで待受を開始する。`port == 0` ならシステムに空きポートを割り当てさせる。
    func start(port desiredPort: UInt16) throws {
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        // 0.0.0.0 相当。iPhone から LAN 経由で繋ぐため全インターフェースで listen する。
        let nwPort = desiredPort == 0 ? NWEndpoint.Port.any : NWEndpoint.Port(rawValue: desiredPort)!
        let listener = try NWListener(using: params, on: nwPort)
        listener.newConnectionHandler = { [weak self] connection in
            self?.accept(connection)
        }
        listener.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed(let error):
                self?.log.error("listener failed: \(String(describing: error))")
            default:
                break
            }
        }
        listener.start(queue: queue)
        self.listener = listener
        // ポート確定を待つ（NWListener.start は非同期に port を割り当てる）。
        let deadline = Date().addingTimeInterval(3)
        while listener.port == nil && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.02)
        }
        guard let boundPort = listener.port?.rawValue else {
            throw MiniHTTPServerError.bindTimeout
        }
        self.port = boundPort
    }

    func stop() {
        listener?.cancel()
        listener = nil
        port = 0
    }

    private func accept(_ connection: NWConnection) {
        connection.start(queue: queue)
        let session = MiniHTTPConnection(connection: connection, maxBodyBytes: maxBodyBytes, handler: handler)
        let key = ObjectIdentifier(session)
        session.onClose = { [weak self] in
            self?.queue.async {
                self?.activeConnections.removeValue(forKey: key)
            }
        }
        activeConnections[key] = session
        session.run()
    }
}

enum MiniHTTPServerError: Error {
    case bindTimeout
}

/// 1 接続分の読み取り→パース→ハンドラ呼び出し→書き込みを担う。
private final class MiniHTTPConnection: @unchecked Sendable {
    private let connection: NWConnection
    private let maxBodyBytes: Int
    private let handler: (HTTPRequest) async -> HTTPResponse
    private var buffer = Data()
    /// `MiniHTTPServer.activeConnections` から自分を取り除いてもらうためのフック。
    var onClose: (() -> Void)?

    init(connection: NWConnection, maxBodyBytes: Int, handler: @escaping (HTTPRequest) async -> HTTPResponse) {
        self.connection = connection
        self.maxBodyBytes = maxBodyBytes
        self.handler = handler
    }

    func run() {
        receiveHeaders()
    }

    private func receiveHeaders() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let data, !data.isEmpty {
                self.buffer.append(data)
            }
            if let range = self.buffer.range(of: Data("\r\n\r\n".utf8)) {
                self.handleHeadersReady(headerEnd: range.upperBound)
                return
            }
            if error != nil || isComplete {
                self.close()
                return
            }
            if self.buffer.count > 1 * 1024 * 1024 {
                self.writeAndClose(.text(431, "Request Header Fields Too Large"))
                return
            }
            self.receiveHeaders()
        }
    }

    private func handleHeadersReady(headerEnd: Data.Index) {
        let headerBlob = buffer.subdata(in: buffer.startIndex..<headerEnd)
        let alreadyRead = buffer.subdata(in: headerEnd..<buffer.endIndex)
        guard let (method, path, query, headers) = Self.parseHeadBlock(headerBlob) else {
            writeAndClose(.text(400, "Bad Request"))
            return
        }
        let contentLength = Int(headers["content-length"] ?? "0") ?? 0
        if contentLength > maxBodyBytes {
            writeAndClose(.json(413, ["error": "body exceeds limit (\(contentLength) > \(maxBodyBytes))"]))
            return
        }
        if contentLength <= 0 {
            dispatch(method: method, path: path, query: query, headers: headers, body: Data())
            return
        }
        var body = alreadyRead
        if body.count >= contentLength {
            dispatch(method: method, path: path, query: query, headers: headers, body: body.prefix(contentLength))
            return
        }
        receiveBody(accumulated: body, target: contentLength) { [weak self] finalBody in
            self?.dispatch(method: method, path: path, query: query, headers: headers, body: finalBody)
        }
    }

    private func receiveBody(accumulated: Data, target: Int, completion: @escaping (Data) -> Void) {
        let remaining = target - accumulated.count
        if remaining <= 0 {
            completion(accumulated)
            return
        }
        connection.receive(minimumIncompleteLength: 1, maximumLength: min(remaining, 256 * 1024)) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            var next = accumulated
            if let data, !data.isEmpty {
                next.append(data)
            }
            if next.count >= target {
                completion(next)
                return
            }
            if error != nil || isComplete {
                // 相手が早期に切断。読めた分だけで応答を試みる。
                completion(next)
                return
            }
            self.receiveBody(accumulated: next, target: target, completion: completion)
        }
    }

    private func dispatch(method: String, path: String, query: [String: String], headers: [String: String], body: Data) {
        let request = HTTPRequest(method: method, path: path, query: query, headers: headers, body: body)
        Task {
            let response = await handler(request)
            self.writeAndClose(response)
        }
    }

    private func writeAndClose(_ response: HTTPResponse) {
        var head = "HTTP/1.1 \(response.status) \(HTTPStatusText.reason(for: response.status))\r\n"
        var headers = response.headers
        headers["Content-Length"] = String(response.body.count)
        headers["Connection"] = "close"
        for (key, value) in headers {
            head += "\(key): \(value)\r\n"
        }
        head += "\r\n"
        var payload = Data(head.utf8)
        payload.append(response.body)
        connection.send(content: payload, completion: .contentProcessed { [weak self] _ in
            self?.close()
        })
    }

    private func close() {
        connection.cancel()
        onClose?()
        onClose = nil
    }

    /// リクエストライン + ヘッダブロックをパースする。`headerBlob` は末尾の `\r\n\r\n` を含まない。
    private static func parseHeadBlock(_ headerBlob: Data) -> (method: String, path: String, query: [String: String], headers: [String: String])? {
        guard let text = String(data: headerBlob, encoding: .utf8) else { return nil }
        var lines = text.components(separatedBy: "\r\n")
        guard !lines.isEmpty else { return nil }
        let requestLine = lines.removeFirst()
        let parts = requestLine.split(separator: " ", maxSplits: 2)
        guard parts.count >= 2 else { return nil }
        let method = String(parts[0]).uppercased()
        let rawTarget = String(parts[1])
        let (path, query) = Self.splitTarget(rawTarget)

        var headers: [String: String] = [:]
        for line in lines {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = line[line.startIndex..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            headers[key] = value
        }
        return (method, path, query, headers)
    }

    private static func splitTarget(_ target: String) -> (String, [String: String]) {
        guard let qIndex = target.firstIndex(of: "?") else {
            return (target.removingPercentEncodingSafe, [:])
        }
        let path = String(target[target.startIndex..<qIndex]).removingPercentEncodingSafe
        let queryString = String(target[target.index(after: qIndex)...])
        var query: [String: String] = [:]
        for pair in queryString.split(separator: "&") {
            let kv = pair.split(separator: "=", maxSplits: 1)
            guard let k = kv.first else { continue }
            let key = String(k).removingPercentEncodingSafe
            let value = kv.count > 1 ? String(kv[1]).removingPercentEncodingSafe : ""
            query[key] = value
        }
        return (path, query)
    }
}

private extension String {
    var removingPercentEncodingSafe: String {
        removingPercentEncoding ?? self
    }
}
