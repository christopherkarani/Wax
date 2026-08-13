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
    case toc
    case footerWrite = "footer_write"
    case footer
    case header

    var checkpoint: String {
        switch self {
        case .toc:
            return "after_toc_write_before_footer"
        case .footerWrite:
            return "after_footer_write_before_fsync"
        case .footer:
            return "after_footer_fsync_before_header"
        case .header:
            return "after_header_write_before_final_fsync"
        }
    }

    /// Whether the in-flight payload frame is expected in the committed TOC after SIGKILL.
    var inFlightCommitIsDurable: Bool {
        switch self {
        case .toc:
            return false
        case .footerWrite, .footer, .header:
            return true
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
    private static let crashAfterAutoCommitsEnv = "WAX_CRASH_INJECT_AFTER_AUTOCOMMITS"
    private static let ackPathEnv = "WAX_CRASH_HARNESS_ACK_PATH"
    private static let publicWalSize = Memory.Config.defaultWalSizeBytes

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
        let ackURL = url.deletingPathExtension().appendingPathExtension("ack")
        defer { try? FileManager.default.removeItem(at: ackURL) }

        let child = try runChildProcess(storeURL: url, scenario: scenario, ackURL: ackURL)
        guard child.reason == .uncaughtSignal, child.status == sigKillStatus else {
            throw HarnessError.childDidNotCrash(status: child.status, reason: child.reason)
        }

        let acked = try readAckedSearchTexts(at: ackURL)
        guard acked.count >= 3 else {
            throw HarnessError.invariantFailed(
                "scenario \(scenario.rawValue) expected at least 3 auto-committed frames, got \(acked.count)"
            )
        }

        let recovered = try await WaxCore.Wax.open(at: url, options: WaxOptions(walReplayStateSnapshotEnabled: true))
        let committedTexts = Set((await recovered.frameMetas()).compactMap(\.searchText))
        for text in acked {
            guard committedTexts.contains(text) else {
                throw HarnessError.invariantFailed(
                    "scenario \(scenario.rawValue) missing auto-committed frame \(text)"
                )
            }
        }

        let seed = try await recovered.frameContent(frameId: seedFrameId)
        guard seed == Data("seed".utf8) else {
            throw HarnessError.invariantFailed("seed frame mismatch after recovery")
        }

        let payloadText = "payload-\(scenario.rawValue)"
        if scenario.inFlightCommitIsDurable {
            guard committedTexts.contains(payloadText) else {
                throw HarnessError.invariantFailed("in-flight payload missing for \(scenario.rawValue)")
            }
        } else {
            guard !committedTexts.contains(payloadText) else {
                throw HarnessError.invariantFailed("toc crash unexpectedly committed in-flight payload")
            }
        }

        let ids = (await recovered.frameMetas()).map(\.id)
        guard Set(ids).count == ids.count else {
            throw HarnessError.invariantFailed("duplicate frame ids after recovery")
        }
        try await recovered.close()
    }

    /// Seeds the store with a single "seed" frame and returns its allocated frame ID.
    @discardableResult
    private static func seedStore(at url: URL) async throws -> UInt64 {
        let wax = try await WaxCore.Wax.create(
            at: url,
            walSize: publicWalSize,
            options: WaxOptions(walReplayStateSnapshotEnabled: true)
        )
        let seedFrameId = try await wax.put(Data("seed".utf8), options: FrameMetaSubset(searchText: "seed"))
        try await wax.commit()
        try await wax.close()
        return seedFrameId
    }

    private static func runChildProcess(
        storeURL: URL,
        scenario: CrashScenario,
        ackURL: URL
    ) throws -> (status: Int32, reason: Process.TerminationReason) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
        var env = ProcessInfo.processInfo.environment
        env[roleEnv] = "child"
        env[storePathEnv] = storeURL.path
        env[scenarioEnv] = scenario.rawValue
        env[crashCheckpointEnv] = scenario.checkpoint
        env[crashAfterAutoCommitsEnv] = "3"
        env[ackPathEnv] = ackURL.path
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
        guard let ackPath = env[ackPathEnv], !ackPath.isEmpty else {
            throw HarnessError.missingEnv(ackPathEnv)
        }

        let url = URL(fileURLWithPath: storePath)
        let wax = try await WaxCore.Wax.open(at: url, options: WaxOptions(walReplayStateSnapshotEnabled: true))
        var acked: [String] = []
        var index = 0
        var autoCommits: UInt64 = 0
        while autoCommits < 3 {
            let text = "ack-\(index)-" + String(repeating: "p", count: 8_192)
            _ = try await wax.put(
                Data("ack-\(index)".utf8),
                options: FrameMetaSubset(searchText: text)
            )
            acked.append(text)
            autoCommits = (await wax.walStats()).autoCommitCount
            index += 1
            if index > 4_000 {
                throw HarnessError.invariantFailed("failed to reach 3 auto-commits on 4 MiB WAL")
            }
        }
        if (await wax.walStats()).pendingBytes > 0, !acked.isEmpty {
            // The put that tripped the last auto-commit is still pending.
            acked.removeLast()
        }
        try Data(acked.joined(separator: "\n").utf8).write(to: URL(fileURLWithPath: ackPath), options: .atomic)

        _ = try await wax.put(
            Data("payload-\(scenario.rawValue)".utf8),
            options: FrameMetaSubset(searchText: "payload-\(scenario.rawValue)")
        )
        try await wax.commit()
        try await wax.close()
    }

    private static func readAckedSearchTexts(at url: URL) throws -> [String] {
        let body = try String(contentsOf: url, encoding: .utf8)
        return body.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
    }
}
