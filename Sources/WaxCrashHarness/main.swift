import Foundation
import Wax
import WaxCore

private enum HarnessError: Error, CustomStringConvertible {
    case invalidArgument(String)
    case missingEnv(String)
    case childDidNotCrash(status: Int32, reason: Process.TerminationReason)
    case invariantFailed(String)

    var description: String {
        switch self {
        case .invalidArgument(let message):
            return "invalid argument: \(message)"
        case .missingEnv(let key):
            return "missing environment variable: \(key)"
        case .childDidNotCrash(let status, let reason):
            return "child did not terminate by SIGKILL (status=\(status), reason=\(reason.rawValue))"
        case .invariantFailed(let message):
            return "invariant failed: \(message)"
        }
    }
}

private enum CrashScenario: String, CaseIterable {
    case segment
    case toc
    case footer
    case header

    var checkpoint: String {
        switch self {
        case .segment:
            return "after_vector_run_write_before_toc"
        case .toc:
            return "after_toc_write_before_footer"
        case .footer:
            return "after_footer_fsync_before_header"
        case .header:
            return "after_header_write_before_final_fsync"
        }
    }

    var expectedCommittedFramesAfterRecovery: UInt64 {
        switch self {
        case .segment, .toc:
            return 1
        case .footer, .header:
            return 2
        }
    }
}

@main
struct WaxCrashHarness {
    private static let sigKillStatus: Int32 = 9
    private static let roleEnv = "WAX_CRASH_HARNESS_ROLE"
    private static let storePathEnv = "WAX_CRASH_HARNESS_STORE_PATH"
    private static let scenarioEnv = "WAX_CRASH_HARNESS_SCENARIO"
    private static let crashCheckpointEnv = "WAX_CRASH_INJECT_CHECKPOINT"
    private static let childTimeoutSeconds: TimeInterval = 120

    private static func writeStderr(_ message: String) {
        guard let data = (message + "\n").data(using: .utf8) else { return }
        FileHandle.standardError.write(data)
    }

    static func main() async {
        do {
            if ProcessInfo.processInfo.environment[roleEnv] == "child" {
                try await runChild()
                writeStderr("child path returned without injected crash")
                Foundation.exit(33)
            }

            let args = CommandLine.arguments
            let requested = try parseRequestedScenarios(args: args)
            for scenario in requested {
                try await runScenario(scenario)
                print("PASS \(scenario.rawValue)")
            }
        } catch {
            writeStderr("FAIL \(error)")
            Foundation.exit(1)
        }
    }

    private static func parseRequestedScenarios(args: [String]) throws -> [CrashScenario] {
        if let index = args.firstIndex(of: "--scenario") {
            let valueIndex = args.index(after: index)
            guard valueIndex < args.endIndex else {
                throw HarnessError.invalidArgument("--scenario requires a value")
            }
            guard let scenario = CrashScenario(rawValue: args[valueIndex]) else {
                throw HarnessError.invalidArgument("unknown scenario '\(args[valueIndex])'")
            }
            return [scenario]
        }
        return CrashScenario.allCases
    }

    private static func runScenario(_ scenario: CrashScenario) async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("wax-crash-harness-\(scenario.rawValue)-\(UUID().uuidString)")
            .appendingPathExtension("wax")
        defer { try? FileManager.default.removeItem(at: url) }

        let seedFrameId = try await seedStore(at: url)

        let child = try runChildProcess(storeURL: url, scenario: scenario)
        guard child.reason == .uncaughtSignal, child.status == sigKillStatus else {
            throw HarnessError.childDidNotCrash(status: child.status, reason: child.reason)
        }

        let recovered = try await WaxCore.Wax.open(at: url, options: WaxOptions(walReplayStateSnapshotEnabled: true))
        let stats = await recovered.stats()
        guard stats.frameCount == scenario.expectedCommittedFramesAfterRecovery else {
            throw HarnessError.invariantFailed(
                "scenario \(scenario.rawValue) expected frameCount \(scenario.expectedCommittedFramesAfterRecovery), got \(stats.frameCount)"
            )
        }
        let seed = try await recovered.frameContent(frameId: seedFrameId)
        guard seed == Data("seed".utf8) else {
            throw HarnessError.invariantFailed("seed frame mismatch after recovery")
        }

        try await checkVectors(recovered, scenario: scenario, seedFrameId: seedFrameId)

        if scenario.expectedCommittedFramesAfterRecovery >= 2 {
            // The child's frame is the next frame allocated after the seed frame.
            let second = try await recovered.frameContent(frameId: seedFrameId + 1)
            let expected = Data("payload-\(scenario.rawValue)".utf8)
            guard second == expected else {
                throw HarnessError.invariantFailed("second frame mismatch for \(scenario.rawValue)")
            }
        }
        try await recovered.close()
    }

    private static func vector(_ frameId: UInt64) -> [Float] {
        (0..<8).map { Float(frameId + 1) + Float($0) * 0.125 }
    }

    /// The seed's vector is committed. The child's vector is committed when its commit
    /// survived, and replays as pending otherwise.
    private static func checkVectors(_ wax: WaxCore.Wax, scenario: CrashScenario, seedFrameId: UInt64) async throws {
        let childFrameId = seedFrameId + 1
        let childCommitted = scenario.expectedCommittedFramesAfterRecovery >= 2
        var expected: [UInt64: [Float]] = [seedFrameId: vector(seedFrameId)]
        if childCommitted { expected[childFrameId] = vector(childFrameId) }
        guard let committed = try await wax.readCommittedVectors() else {
            throw HarnessError.invariantFailed("no committed vectors after \(scenario.rawValue)")
        }
        var found: [UInt64: [Float]] = [:]
        for (row, frameId) in committed.frameIds.enumerated() {
            found[frameId] = Array(committed.vectors[(row * 8)..<((row + 1) * 8)])
        }
        guard found == expected else {
            throw HarnessError.invariantFailed("committed vectors mismatch after \(scenario.rawValue): \(found.keys.sorted())")
        }
        let pending = await wax.pendingEmbeddingMutations(since: nil).embeddings.map(\.frameId)
        guard pending == (childCommitted ? [] : [childFrameId]) else {
            throw HarnessError.invariantFailed("pending vectors mismatch after \(scenario.rawValue): \(pending)")
        }
    }

    /// Seeds the store with a single "seed" frame and its vector, and returns its frame ID.
    @discardableResult
    private static func seedStore(at url: URL) async throws -> UInt64 {
        let wax = try await WaxCore.Wax.create(at: url, options: WaxOptions(walReplayStateSnapshotEnabled: true))
        let seedFrameId = try await wax.put(Data("seed".utf8), options: FrameMetaSubset(searchText: "seed"))
        try await wax.setVectorIndexConfiguration(dimension: 8, similarity: .cosine)
        try await wax.putEmbedding(frameId: seedFrameId, vector: vector(seedFrameId))
        try await wax.commit()
        try await wax.close()
        return seedFrameId
    }

    private static func runChildProcess(storeURL: URL, scenario: CrashScenario) throws -> (status: Int32, reason: Process.TerminationReason) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
        var env = ProcessInfo.processInfo.environment
        env[roleEnv] = "child"
        env[storePathEnv] = storeURL.path
        env[scenarioEnv] = scenario.rawValue
        env[crashCheckpointEnv] = scenario.checkpoint
        process.environment = env
        try process.run()
        // The child crashes itself at its checkpoint; the bound only stops a
        // wedged wait from hanging the harness and the test that runs it.
        guard process.waitForExit(timeout: childTimeoutSeconds) != nil else {
            throw HarnessError.invariantFailed("child for \(scenario.rawValue) did not exit in \(childTimeoutSeconds)s")
        }
        return (status: process.terminationStatus, reason: process.terminationReason)
    }

    private static func runChild() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let storePath = env[storePathEnv], !storePath.isEmpty else {
            throw HarnessError.missingEnv(storePathEnv)
        }
        guard let scenarioName = env[scenarioEnv], let scenario = CrashScenario(rawValue: scenarioName) else {
            throw HarnessError.missingEnv(scenarioEnv)
        }

        let url = URL(fileURLWithPath: storePath)
        let wax = try await WaxCore.Wax.open(at: url, options: WaxOptions(walReplayStateSnapshotEnabled: true))
        let frameId = try await wax.put(
            Data("payload-\(scenario.rawValue)".utf8),
            options: FrameMetaSubset(searchText: "payload-\(scenario.rawValue)")
        )
        try await wax.putEmbedding(frameId: frameId, vector: vector(frameId))
        try await wax.commit()
        try await wax.close()
    }
}
