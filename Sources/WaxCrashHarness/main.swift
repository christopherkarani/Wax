import Foundation
import Wax

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
    case toc
    case footer
    case header

    var checkpoint: String {
        switch self {
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
        case .toc:
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

    static func main() async {
        do {
            if ProcessInfo.processInfo.environment[roleEnv] == "child" {
                try await runChild()
                fputs("child path returned without injected crash\n", stderr)
                Foundation.exit(33)
            }

            let args = CommandLine.arguments
            let requested = try parseRequestedScenarios(args: args)
            for scenario in requested {
                try await runScenario(scenario)
                print("PASS \(scenario.rawValue)")
            }
        } catch {
            fputs("FAIL \(error)\n", stderr)
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
            .appendingPathExtension("mv2s")
        defer { try? FileManager.default.removeItem(at: url) }

        let seedFrameId = try await seedStore(at: url)

        let child = try runChildProcess(storeURL: url, scenario: scenario)
        guard child.reason == .uncaughtSignal, child.status == sigKillStatus else {
            throw HarnessError.childDidNotCrash(status: child.status, reason: child.reason)
        }

        let recovered = try await Wax.open(at: url, options: WaxOptions(walReplayStateSnapshotEnabled: true))
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

    /// Seeds the store with a single "seed" frame and returns its allocated frame ID.
    @discardableResult
    private static func seedStore(at url: URL) async throws -> UInt64 {
        let wax = try await Wax.create(at: url, options: WaxOptions(walReplayStateSnapshotEnabled: true))
        let seedFrameId = try await wax.put(Data("seed".utf8), options: FrameMetaSubset(searchText: "seed"))
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
        process.waitUntilExit()
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
        let wax = try await Wax.open(at: url, options: WaxOptions(walReplayStateSnapshotEnabled: true))
        _ = try await wax.put(
            Data("payload-\(scenario.rawValue)".utf8),
            options: FrameMetaSubset(searchText: "payload-\(scenario.rawValue)")
        )
        try await wax.commit()
        try await wax.close()
    }
}
