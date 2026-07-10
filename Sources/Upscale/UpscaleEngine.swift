import Foundation

enum UpscaleEngine: String, CaseIterable, Sendable {
    case waifu2x = "waifu2x"
    case realCUGAN = "realCUGAN"
    case realESRGAN = "realESRGAN"

    /// `~/.liberaro/<dir>/` の配置ディレクトリ名（`install_ncnn_vulkan.command` と同じレイアウト）。
    var installDirName: String {
        switch self {
        case .waifu2x: return "waifu2x"
        case .realCUGAN: return "realcugan"
        case .realESRGAN: return "realesrgan"
        }
    }

    var binaryName: String {
        switch self {
        case .waifu2x: return "waifu2x-ncnn-vulkan"
        case .realCUGAN: return "realcugan-ncnn-vulkan"
        case .realESRGAN: return "realesrgan-ncnn-vulkan"
        }
    }

    var envBinOverrideKey: String {
        switch self {
        case .waifu2x: return "LIBERARO_WAIFU2X_BIN"
        case .realCUGAN: return "LIBERARO_REALCUGAN_BIN"
        case .realESRGAN: return "LIBERARO_REALESRGAN_BIN"
        }
    }
}

/// エンジンのバイナリ/モデルディレクトリ探索。`~/.liberaro/<engine>/` を最優先で見る
/// (`install_ncnn_vulkan.command` の配置先と一致)。環境変数で明示上書きも可能。
struct UpscaleEngineResolver {
    let liberaroRoot: URL

    init(liberaroRoot: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".liberaro")) {
        self.liberaroRoot = liberaroRoot
    }

    func binaryPath(for engine: UpscaleEngine) -> URL? {
        if let override = ProcessInfo.processInfo.environment[engine.envBinOverrideKey], !override.isEmpty {
            return URL(fileURLWithPath: override)
        }
        let candidate = liberaroRoot
            .appendingPathComponent(engine.installDirName)
            .appendingPathComponent(engine.binaryName)
        if FileManager.default.isExecutableFile(atPath: candidate.path) {
            return candidate
        }
        return nil
    }

    func modelsRoot(for engine: UpscaleEngine) -> URL? {
        guard let bin = binaryPath(for: engine) else { return nil }
        return bin.deletingLastPathComponent()
    }

    /// `models-*` (waifu2x/realCUGAN) または `.param` prefix (realESRGAN) の一覧。
    func availableModels(for engine: UpscaleEngine) -> [String] {
        guard let root = modelsRoot(for: engine) else { return [] }
        let fm = FileManager.default
        switch engine {
        case .waifu2x, .realCUGAN:
            guard let entries = try? fm.contentsOfDirectory(atPath: root.path) else { return [] }
            return entries
                .filter { $0.hasPrefix("models-") }
                .map { String($0.dropFirst("models-".count)) }
                .sorted()
        case .realESRGAN:
            let modelsDir = root.appendingPathComponent("models")
            guard let entries = try? fm.contentsOfDirectory(atPath: modelsDir.path) else { return [] }
            let names = entries
                .filter { $0.hasSuffix(".param") }
                .map { String($0.dropLast(".param".count)) }
            return Array(Set(names)).sorted()
        }
    }

    func availableEngines() -> [UpscaleEngine: Bool] {
        Dictionary(uniqueKeysWithValues: UpscaleEngine.allCases.map { ($0, binaryPath(for: $0) != nil) })
    }
}

enum UpscaleCommandBuilder {
    /// `models-` prefix を剥がす（iOS 側のリモート専用 picker が `models-pro` のように
    /// 貼っても動くようにする）。
    static func stripModelsPrefix(_ modelID: String) -> String {
        modelID.hasPrefix("models-") ? String(modelID.dropFirst("models-".count)) : modelID
    }

    static func tileArgs() -> [String] {
        guard let raw = ProcessInfo.processInfo.environment["LIBERARO_UPSCALE_TILE_SIZE"],
              let size = Int(raw), size > 0 else { return [] }
        return ["-t", String(size)]
    }

    static func build(engine: UpscaleEngine, binary: URL, modelsRoot: URL, job: UpscaleJob) -> [String] {
        switch engine {
        case .waifu2x: return buildWaifu2x(binary: binary, modelsRoot: modelsRoot, job: job)
        case .realCUGAN: return buildRealCUGAN(binary: binary, modelsRoot: modelsRoot, job: job)
        case .realESRGAN: return buildRealESRGAN(binary: binary, modelsRoot: modelsRoot, job: job)
        }
    }

    private static func buildWaifu2x(binary: URL, modelsRoot: URL, job: UpscaleJob) -> [String] {
        var argv = [binary.path, "-i", job.inputPath, "-o", job.outputPath]
        argv += ["-s", String(max(1, job.scale))]
        argv += tileArgs()
        if (-1...3).contains(job.noise) {
            argv += ["-n", String(job.noise)]
        }
        let model = stripModelsPrefix(job.modelID)
        if !model.isEmpty {
            argv += ["-m", modelsRoot.appendingPathComponent("models-\(model)").path]
        }
        return argv
    }

    private static func buildRealCUGAN(binary: URL, modelsRoot: URL, job: UpscaleJob) -> [String] {
        var argv = [binary.path, "-i", job.inputPath, "-o", job.outputPath]
        argv += ["-s", String(max(2, job.scale))]
        argv += tileArgs()
        if [-1, 0, 3].contains(job.noise) {
            argv += ["-n", String(job.noise)]
        }
        let model = stripModelsPrefix(job.modelID)
        if !model.isEmpty {
            argv += ["-m", modelsRoot.appendingPathComponent("models-\(model)").path]
        }
        return argv
    }

    private static func buildRealESRGAN(binary: URL, modelsRoot: URL, job: UpscaleJob) -> [String] {
        var argv = [binary.path, "-i", job.inputPath, "-o", job.outputPath]
        argv += ["-s", String(max(2, job.scale))]
        argv += tileArgs()
        let modelsDir = modelsRoot.appendingPathComponent("models")
        if FileManager.default.fileExists(atPath: modelsDir.path) {
            argv += ["-m", modelsDir.path]
        }
        let model = stripModelsPrefix(job.modelID)
        if !model.isEmpty {
            argv += ["-n", model]
        }
        return argv
    }
}
