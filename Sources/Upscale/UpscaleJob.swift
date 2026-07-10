import Foundation

enum UpscaleJobStatus: String, Codable, Sendable {
    case queued, processing, done, failed, cancelled

    var isTerminal: Bool {
        switch self {
        case .done, .failed, .cancelled: return true
        case .queued, .processing: return false
        }
    }
}

/// `MacUpscaleClient` (iOS) が読む JSON 契約と一致させる。
/// フィールド名は `mac-sidecar/upscale/liberaro_upscale_server.py` の `_job_status_payload` と同一。
struct UpscaleJob: Sendable {
    let id: String
    var status: UpscaleJobStatus
    var error: String?
    let engine: String
    let modelID: String
    let scale: Int
    let noise: Int
    let noUpscale: Bool
    let skipMinPixel: Int
    let createdAt: Double
    var updatedAt: Double
    var finishedAt: Double?
    var cancelRequested: Bool = false

    let tmpDir: URL
    var inputPath: String
    let outputPath: String

    func statusPayload(resultAvailable: Bool, resultBytes: Int?, retentionSeconds: Int) -> [String: Any] {
        var dict: [String: Any] = [
            "id": id,
            "status": status.rawValue,
            "error": error as Any,
            "engine": engine,
            "modelID": modelID,
            "scale": scale,
            "noise": noise,
            "noUpscale": noUpscale,
            "skipMinPixel": skipMinPixel,
            "createdAt": createdAt,
            "updatedAt": updatedAt,
            "finishedAt": finishedAt as Any,
            "resultAvailable": resultAvailable,
            "retentionSeconds": retentionSeconds,
        ]
        if let resultBytes {
            dict["resultBytes"] = resultBytes
        } else {
            dict["resultBytes"] = NSNull()
        }
        if error == nil { dict["error"] = NSNull() }
        if finishedAt == nil { dict["finishedAt"] = NSNull() }
        return dict
    }
}

/// `GET /progress` の集計。`[String: Any]` は actor 境界を跨げない (non-Sendable) ため、
/// Sendable な struct で保持し、HTTP 応答時にだけ dict へ変換する。
struct UpscaleProgress: Sendable {
    var total: Int
    var queued: Int
    var processing: Int
    var done: Int
    var failed: Int
    var cancelled: Int
    var remaining: Int
    var avgSeconds: Double?
    var etaSeconds: Double?
    var updatedAt: Double

    func jsonObject() -> [String: Any] {
        var dict: [String: Any] = [
            "total": total,
            "queued": queued,
            "processing": processing,
            "done": done,
            "failed": failed,
            "cancelled": cancelled,
            "remaining": remaining,
            "updatedAt": updatedAt,
        ]
        dict["avgSeconds"] = avgSeconds ?? NSNull()
        dict["etaSeconds"] = etaSeconds ?? NSNull()
        return dict
    }
}

struct UpscaleJobMeta {
    var engine: String
    var modelID: String
    var scale: Int
    var noise: Int
    var noUpscale: Bool
    var skipMinPixel: Int

    static func parse(_ json: [String: Any]) -> UpscaleJobMeta {
        UpscaleJobMeta(
            engine: json["engine"] as? String ?? "",
            modelID: json["modelID"] as? String ?? "",
            scale: (json["scale"] as? NSNumber)?.intValue ?? 1,
            noise: (json["noise"] as? NSNumber)?.intValue ?? -1,
            noUpscale: (json["noUpscale"] as? NSNumber)?.boolValue ?? (json["noUpscale"] as? Bool ?? false),
            skipMinPixel: (json["skipMinPixel"] as? NSNumber)?.intValue ?? 0
        )
    }
}
