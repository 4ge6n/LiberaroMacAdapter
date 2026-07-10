import Foundation
import os.log

/// `mac-sidecar/upscale/liberaro_upscale_server.py` と同一のワイヤープロトコルを話す
/// ネイティブ実装。iOS 側 (`MacUpscaleClient`) は無改修でこのサービスに接続できる。
final class UpscaleHTTPService: @unchecked Sendable {
    static let serverVersion = "1.0.0-adapter"
    static let defaultMaxImageBytes = 60 * 1024 * 1024
    static let defaultMaxMultipartBytes = 80 * 1024 * 1024
    static let defaultMaxImagePixels = 120_000_000
    static let defaultMaxScale = 4

    private let log = Logger(subsystem: "com.4ge6n.LiberaroMacAdapter", category: "upscale.http")
    let store: UpscaleJobStore
    let resolver: UpscaleEngineResolver
    private(set) var server: MiniHTTPServer?
    let token: String

    init(store: UpscaleJobStore, resolver: UpscaleEngineResolver, token: String) {
        self.store = store
        self.resolver = resolver
        self.token = token
    }

    @discardableResult
    func start(port: UInt16) throws -> UInt16 {
        let server = MiniHTTPServer(maxBodyBytes: Self.defaultMaxMultipartBytes) { [weak self] request in
            await self?.handle(request) ?? .text(503, "service unavailable")
        }
        try server.start(port: port)
        self.server = server
        Task { await store.startWorkersIfNeeded() }
        log.info("upscale service listening on port \(server.port)")
        return server.port
    }

    func stop() {
        server?.stop()
        server = nil
    }

    var boundPort: UInt16 { server?.port ?? 0 }

    // MARK: - Routing

    private func handle(_ request: HTTPRequest) async -> HTTPResponse {
        guard AuthTokenStore.isAuthorized(headers: request.headers, token: token) else {
            return .json(401, ["error": "unauthorized"])
        }
        switch (request.method, request.path) {
        case ("GET", "/health"):
            return handleHealth()
        case ("GET", "/models"):
            return handleModels()
        case ("GET", "/jobs"), ("GET", "/jobs/"):
            return await handleListJobs()
        case ("GET", "/progress"), ("GET", "/progress/"):
            return await handleProgress()
        case ("POST", "/jobs"):
            return await handleCreateJob(request)
        default:
            if request.method == "GET", request.path.hasPrefix("/jobs/") {
                return await handleJobAction(path: request.path)
            }
            if request.method == "DELETE", request.path.hasPrefix("/jobs/") {
                return await handleDeleteJob(path: request.path)
            }
            return .json(404, ["error": "not found"])
        }
    }

    private func handleHealth() -> HTTPResponse {
        let engines = resolver.availableEngines()
        var enginesJSON: [String: Bool] = [:]
        for (engine, available) in engines { enginesJSON[engine.rawValue] = available }
        return .json(200, ["status": "ok", "version": Self.serverVersion, "engines": enginesJSON])
    }

    private func handleModels() -> HTTPResponse {
        var models: [String: [String]] = [:]
        for engine in UpscaleEngine.allCases {
            models[engine.rawValue] = resolver.availableModels(for: engine)
        }
        return .json(200, ["models": models])
    }

    private func handleListJobs() async -> HTTPResponse {
        let jobs = await store.allJobsSortedByCreatedDesc()
        let payloads = jobs.map { payload(for: $0) }
        return .json(200, ["jobs": payloads])
    }

    private func handleProgress() async -> HTTPResponse {
        .json(200, await store.progressSnapshot().jsonObject())
    }

    private func handleCreateJob(_ request: HTTPRequest) async -> HTTPResponse {
        guard let contentType = request.header("content-type"), contentType.hasPrefix("multipart/form-data") else {
            return .json(400, ["error": "expected multipart/form-data with 'image' and 'meta' fields"])
        }
        guard let boundary = MultipartParser.extractBoundary(contentType: contentType) else {
            return .json(400, ["error": "multipart boundary not found in Content-Type"])
        }
        guard let parts = MultipartParser.parse(body: request.body, boundary: boundary),
              let imagePart = parts["image"], let metaPart = parts["meta"] else {
            return .json(400, ["error": "missing 'image' or 'meta' field"])
        }
        guard let metaObject = try? JSONSerialization.jsonObject(with: metaPart.body) as? [String: Any] else {
            return .json(400, ["error": "meta is not valid JSON"])
        }
        let meta = UpscaleJobMeta.parse(metaObject)
        if meta.scale < 1 || meta.scale > Self.defaultMaxScale {
            return .json(400, ["error": "scale must be between 1 and \(Self.defaultMaxScale)"])
        }
        guard !imagePart.body.isEmpty else {
            return .json(400, ["error": "'image' part is empty"])
        }
        if imagePart.body.count > Self.defaultMaxImageBytes {
            return .json(413, ["error": "image exceeds limit (\(imagePart.body.count) > \(Self.defaultMaxImageBytes))"])
        }

        let stagingDir = store.jobRoot.appendingPathComponent("_staging")
        try? FileManager.default.createDirectory(at: stagingDir, withIntermediateDirectories: true)
        let stagedPath = stagingDir.appendingPathComponent(UUID().uuidString + ".bin")
        do {
            try imagePart.body.write(to: stagedPath)
        } catch {
            return .json(500, ["error": "failed to stage upload: \(error)"])
        }

        guard let pixels = ImageProbe.pixelCount(ofFileAt: stagedPath.path), pixels > 0 else {
            try? FileManager.default.removeItem(at: stagedPath)
            return .json(400, ["error": "image is not a readable image"])
        }
        if pixels > Self.defaultMaxImagePixels {
            try? FileManager.default.removeItem(at: stagedPath)
            return .json(400, ["error": "image exceeds MAX_IMAGE_PIXELS (\(pixels) > \(Self.defaultMaxImagePixels))"])
        }

        let job = await store.createJob(meta: meta, stagedInput: stagedPath)
        return .json(201, payload(for: job))
    }

    private func handleJobAction(path: String) async -> HTTPResponse {
        let tail = String(path.dropFirst("/jobs/".count))
        let components = tail.split(separator: "/", maxSplits: 1).map(String.init)
        let jobID = components.first ?? ""
        let action = components.count > 1 ? components[1] : ""
        guard let job = await store.job(jobID) else {
            return .json(404, ["error": "job not found"])
        }
        switch action {
        case "":
            return .json(200, payload(for: job))
        case "result":
            guard job.status == .done else {
                return .json(409, ["error": "job is \(job.status.rawValue), not done"])
            }
            guard let data = FileManager.default.contents(atPath: job.outputPath) else {
                return .json(500, ["error": "result file missing"])
            }
            return .binary(200, data, contentType: "image/png", extraHeaders: [
                "Cache-Control": "no-store",
                "X-Liberaro-Result-Retained": "true",
            ])
        default:
            return .json(404, ["error": "unknown action"])
        }
    }

    private func handleDeleteJob(path: String) async -> HTTPResponse {
        let jobID = String(path.dropFirst("/jobs/".count)).split(separator: "/").first.map(String.init) ?? ""
        guard let job = await store.job(jobID) else {
            return .json(404, ["error": "job not found"])
        }
        if job.status.isTerminal {
            _ = await store.delete(jobID)
            return .json(200, ["deleted": true])
        } else {
            _ = await store.requestCancel(jobID)
            return .json(202, ["cancelling": true])
        }
    }

    private func payload(for job: UpscaleJob) -> [String: Any] {
        let resultAvailable = job.status == .done && FileManager.default.fileExists(atPath: job.outputPath)
        let resultBytes: Int? = resultAvailable
            ? (try? FileManager.default.attributesOfItem(atPath: job.outputPath)[.size] as? Int) ?? nil
            : nil
        return job.statusPayload(
            resultAvailable: resultAvailable,
            resultBytes: resultBytes,
            retentionSeconds: Int(store.retentionSeconds)
        )
    }
}
