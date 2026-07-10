import Foundation
import Combine

@MainActor
final class AppState: ObservableObject {
    @Published var upscaleRunning = false
    @Published var upscalePort: UInt16 = 8088
    @Published var upscaleStartError: String?
    @Published var jobs: [UpscaleJob] = []
    @Published var progress = UpscaleProgress(
        total: 0, queued: 0, processing: 0, done: 0, failed: 0, cancelled: 0,
        remaining: 0, avgSeconds: nil, etaSeconds: nil, updatedAt: 0
    )

    let upscaleToken: String
    let irodoriToken: String
    let irodoriSupervisor: IrodoriSupervisor
    let irodoriHealth = IrodoriHealthMonitor()
    var irodoriPort: UInt16 = 9988

    private let upscaleStore: UpscaleJobStore
    private var upscaleService: UpscaleHTTPService?
    private let supportDir: URL
    private var refreshTask: Task<Void, Never>?

    init() {
        let fm = FileManager.default
        let appSupport = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("LiberaroMacAdapter")
        try? fm.createDirectory(at: appSupport, withIntermediateDirectories: true)
        self.supportDir = appSupport

        self.upscaleToken = AuthTokenStore.loadOrCreate(fileURL: appSupport.appendingPathComponent("upscale_token.txt"))
        self.irodoriToken = AuthTokenStore.loadOrCreate(fileURL: appSupport.appendingPathComponent("irodori_token.txt"))

        let jobRoot = fm.urls(for: .cachesDirectory, in: .userDomainMask).first!
            .appendingPathComponent("LiberaroUpscaleJobs")
        self.upscaleStore = UpscaleJobStore(jobRoot: jobRoot)

        let irodoriJobRoot = fm.urls(for: .cachesDirectory, in: .userDomainMask).first!
            .appendingPathComponent("LiberaroIrodoriBatchJobs")
        let scriptURL = Bundle.main.url(forResource: "irodori_batch_server", withExtension: "py")
            ?? URL(fileURLWithPath: "/dev/null")
        self.irodoriSupervisor = IrodoriSupervisor(scriptURL: scriptURL, jobRoot: irodoriJobRoot, token: irodoriToken)
    }

    func startUpscaleService() {
        guard upscaleService == nil else { return }
        let service = UpscaleHTTPService(store: upscaleStore, resolver: UpscaleEngineResolver(), token: upscaleToken)
        do {
            let port = try service.start(port: upscalePort)
            upscalePort = port
            upscaleService = service
            upscaleRunning = true
            upscaleStartError = nil
            startRefreshLoop()
        } catch {
            upscaleStartError = String(describing: error)
            upscaleRunning = false
        }
    }

    func stopUpscaleService() {
        upscaleService?.stop()
        upscaleService = nil
        upscaleRunning = false
        refreshTask?.cancel()
    }

    func startIrodoriService() {
        irodoriSupervisor.start(port: irodoriPort)
        irodoriHealth.start(port: irodoriPort, token: irodoriToken)
    }

    func stopIrodoriService() {
        irodoriSupervisor.stop()
        irodoriHealth.stop()
    }

    func pairingPayload() -> PairingPayload? {
        guard let host = NetworkInfo.primaryLANAddress() else { return nil }
        return PairingPayload(
            host: host,
            upscalePort: Int(upscalePort),
            upscaleToken: upscaleToken,
            irodoriPort: Int(irodoriPort),
            irodoriToken: irodoriToken
        )
    }

    private func startRefreshLoop() {
        refreshTask?.cancel()
        refreshTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refreshJobs()
                try? await Task.sleep(nanoseconds: 2_000_000_000)
            }
        }
    }

    private func refreshJobs() async {
        jobs = await upscaleStore.allJobsSortedByCreatedDesc()
        progress = await upscaleStore.progressSnapshot()
    }
}
