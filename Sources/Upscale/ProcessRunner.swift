import Foundation

struct ProcessResult {
    var exitCode: Int32
    var stdout: Data
    var stderr: Data
    var wasCancelled: Bool
}

enum ProcessRunnerError: Error {
    case launchFailed(String)
}

/// ncnn-vulkan バイナリを subprocess として起動し、協調的キャンセル
/// (`cancelCheck` を 0.5s おきにポーリングして `terminate()`) をサポートする。
enum ProcessRunner {
    private final class CancelFlag: @unchecked Sendable {
        private let lock = NSLock()
        private var value = false
        func set() { lock.lock(); value = true; lock.unlock() }
        func get() -> Bool { lock.lock(); defer { lock.unlock() }; return value }
    }

    static func run(argv: [String], cancelCheck: @escaping @Sendable () async -> Bool) async throws -> ProcessResult {
        guard !argv.isEmpty else { throw ProcessRunnerError.launchFailed("empty argv") }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: argv[0])
        process.arguments = Array(argv.dropFirst())
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        do {
            try process.run()
        } catch {
            throw ProcessRunnerError.launchFailed(String(describing: error))
        }

        let cancelFlag = CancelFlag()
        let cancelTask = Task.detached {
            while !Task.isCancelled {
                if await cancelCheck() {
                    cancelFlag.set()
                    process.terminate()
                    return
                }
                try? await Task.sleep(nanoseconds: 500_000_000)
            }
        }

        async let stdoutData = readAll(stdoutPipe.fileHandleForReading)
        async let stderrData = readAll(stderrPipe.fileHandleForReading)

        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            process.terminationHandler = { _ in continuation.resume() }
        }
        cancelTask.cancel()

        return ProcessResult(
            exitCode: process.terminationStatus,
            stdout: await stdoutData,
            stderr: await stderrData,
            wasCancelled: cancelFlag.get()
        )
    }

    private static func readAll(_ handle: FileHandle) async -> Data {
        await Task.detached { handle.readDataToEndOfFile() }.value
    }
}
