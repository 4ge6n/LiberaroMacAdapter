import Foundation
import os.log

/// アップロードされた画像のジョブレジストリ + 実行キュー。
/// `mac-sidecar/upscale/liberaro_upscale_server.py` の memory model (0.3.0+) を踏襲:
/// POST /jobs はキューに積むだけ。固定数のワーカーが順番に処理する。
actor UpscaleJobStore {
    private let log = Logger(subsystem: "com.4ge6n.LiberaroMacAdapter", category: "upscale.jobs")

    private(set) var jobs: [String: UpscaleJob] = [:]
    private var pendingQueue: [String] = []
    private var waitingContinuations: [CheckedContinuation<String, Never>] = []

    let jobRoot: URL
    let retentionSeconds: Double
    let maxWorkers: Int
    private let resolver: UpscaleEngineResolver
    private var workersStarted = false

    /// 完了実績 (created→finished 秒数) の直近サンプル。ETA 推定用。
    private var recentDurations: [(finishedAt: Double, duration: Double)] = []

    init(
        jobRoot: URL,
        retentionSeconds: Double = 24 * 60 * 60,
        maxWorkers: Int = 1,
        resolver: UpscaleEngineResolver = UpscaleEngineResolver()
    ) {
        self.jobRoot = jobRoot
        self.retentionSeconds = retentionSeconds
        self.maxWorkers = max(1, maxWorkers)
        self.resolver = resolver
        try? FileManager.default.createDirectory(at: jobRoot, withIntermediateDirectories: true)
    }

    func startWorkersIfNeeded() {
        guard !workersStarted else { return }
        workersStarted = true
        restoreFromDisk()
        for index in 0..<maxWorkers {
            Task.detached(priority: .utility) { [weak self] in
                await self?.workerLoop(index: index)
            }
        }
        Task.detached(priority: .background) { [weak self] in
            await self?.reaperLoop()
        }
    }

    // MARK: - Job lifecycle

    func createJob(meta: UpscaleJobMeta, stagedInput: URL) -> UpscaleJob {
        let id = UUID().uuidString.lowercased().replacingOccurrences(of: "-", with: "")
        let dir = jobRoot.appendingPathComponent(id)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let finalInput = dir.appendingPathComponent("input.bin")
        try? FileManager.default.moveItem(at: stagedInput, to: finalInput)
        let now = Date().timeIntervalSince1970
        let job = UpscaleJob(
            id: id,
            status: .queued,
            error: nil,
            engine: meta.engine,
            modelID: meta.modelID,
            scale: meta.scale,
            noise: meta.noise,
            noUpscale: meta.noUpscale,
            skipMinPixel: meta.skipMinPixel,
            createdAt: now,
            updatedAt: now,
            finishedAt: nil,
            tmpDir: dir,
            inputPath: finalInput.path,
            outputPath: dir.appendingPathComponent("result.png").path
        )
        jobs[id] = job
        persist(job)
        log.info("job \(id.prefix(8), privacy: .public) -> queued engine=\(meta.engine, privacy: .public)")
        enqueue(id)
        return job
    }

    func job(_ id: String) -> UpscaleJob? { jobs[id] }

    func allJobsSortedByCreatedDesc() -> [UpscaleJob] {
        jobs.values.sorted { $0.createdAt > $1.createdAt }
    }

    func requestCancel(_ id: String) -> Bool {
        guard var job = jobs[id], !job.status.isTerminal else { return false }
        job.cancelRequested = true
        if job.status == .queued {
            job.status = .cancelled
            job.finishedAt = Date().timeIntervalSince1970
        }
        jobs[id] = job
        persist(job)
        return true
    }

    func delete(_ id: String) -> Bool {
        guard let job = jobs.removeValue(forKey: id) else { return false }
        try? FileManager.default.removeItem(at: job.tmpDir)
        return true
    }

    func progressSnapshot() -> UpscaleProgress {
        var counts: [UpscaleJobStatus: Int] = [.queued: 0, .processing: 0, .done: 0, .failed: 0, .cancelled: 0]
        for job in jobs.values {
            counts[job.status, default: 0] += 1
        }
        let total = counts.values.reduce(0, +)
        let remaining = (counts[.queued] ?? 0) + (counts[.processing] ?? 0)
        let recent = recentDurations.suffix(20).map(\.duration)
        let avg = recent.isEmpty ? nil : recent.reduce(0, +) / Double(recent.count)
        return UpscaleProgress(
            total: total,
            queued: counts[.queued] ?? 0,
            processing: counts[.processing] ?? 0,
            done: counts[.done] ?? 0,
            failed: counts[.failed] ?? 0,
            cancelled: counts[.cancelled] ?? 0,
            remaining: remaining,
            avgSeconds: avg,
            etaSeconds: avg.map { $0 * Double(remaining) },
            updatedAt: Date().timeIntervalSince1970
        )
    }

    // MARK: - Queue

    private func enqueue(_ id: String) {
        if let continuation = waitingContinuations.first {
            waitingContinuations.removeFirst()
            continuation.resume(returning: id)
        } else {
            pendingQueue.append(id)
        }
    }

    private func dequeue() async -> String {
        if !pendingQueue.isEmpty {
            return pendingQueue.removeFirst()
        }
        return await withCheckedContinuation { continuation in
            waitingContinuations.append(continuation)
        }
    }

    private func workerLoop(index: Int) async {
        while true {
            let id = await dequeue()
            guard let job = jobs[id], job.status == .queued else { continue }
            await run(job)
        }
    }

    private func reaperLoop() async {
        while true {
            try? await Task.sleep(nanoseconds: 300 * 1_000_000_000)
            pruneFinishedJobs()
        }
    }

    private func pruneFinishedJobs() {
        let now = Date().timeIntervalSince1970
        let stale = jobs.values.filter { job in
            guard let finishedAt = job.finishedAt else { return false }
            return (now - finishedAt) > retentionSeconds
        }
        for job in stale {
            _ = delete(job.id)
        }
    }

    // MARK: - Execution

    private func run(_ job: UpscaleJob) async {
        var job = job
        if job.cancelRequested {
            job.status = .cancelled
            job.finishedAt = Date().timeIntervalSince1970
            jobs[job.id] = job
            persist(job)
            return
        }
        job.status = .processing
        job.updatedAt = Date().timeIntervalSince1970
        jobs[job.id] = job
        persist(job)
        log.info("job \(job.id.prefix(8), privacy: .public) -> processing")

        if shouldSkip(job) {
            try? FileManager.default.copyItem(atPath: job.inputPath, toPath: job.outputPath)
            finish(job.id, status: .done)
            return
        }

        guard let engine = UpscaleEngine(rawValue: job.engine) else {
            finish(job.id, status: .failed, error: "unsupported engine: \(job.engine)")
            return
        }
        guard let binary = resolver.binaryPath(for: engine) else {
            finish(job.id, status: .failed, error: "engine '\(job.engine)' is not configured on this Mac")
            return
        }
        let modelsRoot = resolver.modelsRoot(for: engine) ?? binary.deletingLastPathComponent()
        let argv = UpscaleCommandBuilder.build(engine: engine, binary: binary, modelsRoot: modelsRoot, job: job)

        do {
            let jobID = job.id
            let result = try await ProcessRunner.run(argv: argv, cancelCheck: { [weak self] in
                await self?.jobs[jobID]?.cancelRequested ?? false
            })
            if result.wasCancelled {
                finish(job.id, status: .cancelled)
                return
            }
            if result.exitCode != 0 {
                let stderr = String(data: result.stderr, encoding: .utf8) ?? ""
                finish(job.id, status: .failed, error: "exit=\(result.exitCode): \(stderr.prefix(500))")
                return
            }
            guard FileManager.default.fileExists(atPath: job.outputPath) else {
                finish(job.id, status: .failed, error: "binary returned 0 but output file is missing")
                return
            }
            if job.noUpscale {
                try resizeOutputToInputSize(job)
            }
            finish(job.id, status: .done)
        } catch {
            finish(job.id, status: .failed, error: String(describing: error))
        }
    }

    private func shouldSkip(_ job: UpscaleJob) -> Bool {
        guard job.skipMinPixel > 0 else { return false }
        guard let size = ImageProbe.size(ofFileAt: job.inputPath) else { return false }
        return max(size.width, size.height) >= CGFloat(job.skipMinPixel)
    }

    private func resizeOutputToInputSize(_ job: UpscaleJob) throws {
        guard let inputSize = ImageProbe.size(ofFileAt: job.inputPath) else { return }
        if let outputSize = ImageProbe.size(ofFileAt: job.outputPath), outputSize == inputSize { return }
        try ImageProbe.resizePNG(atPath: job.outputPath, to: inputSize)
    }

    private func finish(_ id: String, status: UpscaleJobStatus, error: String? = nil) {
        guard var job = jobs[id] else { return }
        job.status = status
        job.error = error
        job.updatedAt = Date().timeIntervalSince1970
        job.finishedAt = job.updatedAt
        jobs[id] = job
        persist(job)
        if status == .done {
            recentDurations.append((finishedAt: job.finishedAt!, duration: job.finishedAt! - job.createdAt))
            if recentDurations.count > 50 { recentDurations.removeFirst(recentDurations.count - 50) }
        }
        if status == .failed, let error {
            log.error("job \(id.prefix(8), privacy: .public) -> failed: \(error, privacy: .public)")
        } else {
            log.info("job \(id.prefix(8), privacy: .public) -> \(status.rawValue, privacy: .public)")
        }
    }

    // MARK: - Persistence (crash recovery)

    private func persist(_ job: UpscaleJob) {
        let payload: [String: Any] = [
            "id": job.id,
            "status": job.status.rawValue,
            "error": job.error as Any,
            "engine": job.engine,
            "modelID": job.modelID,
            "scale": job.scale,
            "noise": job.noise,
            "noUpscale": job.noUpscale,
            "skipMinPixel": job.skipMinPixel,
            "createdAt": job.createdAt,
            "updatedAt": job.updatedAt,
            "finishedAt": job.finishedAt as Any,
            "cancelRequested": job.cancelRequested,
            "inputPath": job.inputPath,
            "outputPath": job.outputPath,
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted]) else { return }
        let stateURL = job.tmpDir.appendingPathComponent("job.json")
        try? data.write(to: stateURL, options: .atomic)
    }

    private func restoreFromDisk() {
        guard let entries = try? FileManager.default.contentsOfDirectory(at: jobRoot, includingPropertiesForKeys: nil) else { return }
        var requeued: [UpscaleJob] = []
        for dir in entries {
            guard dir.hasDirectoryPath, dir.lastPathComponent != "_staging" else { continue }
            let stateURL = dir.appendingPathComponent("job.json")
            guard let data = try? Data(contentsOf: stateURL),
                  let raw = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let id = raw["id"] as? String,
                  let statusRaw = raw["status"] as? String else { continue }

            var status = UpscaleJobStatus(rawValue: statusRaw) ?? .failed
            let inputPath = (raw["inputPath"] as? String) ?? dir.appendingPathComponent("input.bin").path
            let outputPath = (raw["outputPath"] as? String) ?? dir.appendingPathComponent("result.png").path
            var errorMessage = raw["error"] as? String
            var finishedAt = raw["finishedAt"] as? Double
            let now = Date().timeIntervalSince1970

            if status == .queued || status == .processing {
                if FileManager.default.fileExists(atPath: inputPath) {
                    status = .queued
                    errorMessage = nil
                    finishedAt = nil
                } else {
                    status = .failed
                    errorMessage = "adapter restarted and job input was lost"
                    finishedAt = now
                }
            }

            var job = UpscaleJob(
                id: id,
                status: status,
                error: errorMessage,
                engine: raw["engine"] as? String ?? "",
                modelID: raw["modelID"] as? String ?? "",
                scale: (raw["scale"] as? NSNumber)?.intValue ?? 1,
                noise: (raw["noise"] as? NSNumber)?.intValue ?? -1,
                noUpscale: (raw["noUpscale"] as? NSNumber)?.boolValue ?? false,
                skipMinPixel: (raw["skipMinPixel"] as? NSNumber)?.intValue ?? 0,
                createdAt: (raw["createdAt"] as? NSNumber)?.doubleValue ?? now,
                updatedAt: now,
                finishedAt: finishedAt,
                tmpDir: dir,
                inputPath: inputPath,
                outputPath: outputPath
            )
            job.cancelRequested = (raw["cancelRequested"] as? NSNumber)?.boolValue ?? false
            jobs[id] = job
            persist(job)
            if status == .queued {
                requeued.append(job)
            }
        }
        requeued.sort { $0.createdAt < $1.createdAt }
        for job in requeued {
            enqueue(job.id)
        }
        if !requeued.isEmpty {
            log.info("restored \(requeued.count) in-flight job(s) from disk")
        }
    }
}
