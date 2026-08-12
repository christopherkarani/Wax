import Foundation
import Testing
import Wax

private let reliabilityTrialCount = 20
private let reliabilityOpenLimitSeconds = 15.0
private let evidenceReportPath = URL(
    fileURLWithPath: "/tmp/wax-remediation-evidence-2026-08-12/task-4/fresh-process-report.json"
)

@Suite("MiniLMExternalReliabilityTests")
struct MiniLMExternalReliabilityTests {
@Test
func miniLMFreshProcessReliabilityGate() async throws {
    let binary = try reliabilityHarnessURL()
    let warmup = try runReliabilityChild(binary: binary, trial: 0, forced: true)
    #expect(warmup.embeddingStatus == "active", "warmup status \(warmup.embeddingStatus)")

    var reports: [ReliabilityChildReport] = []
    reports.reserveCapacity(reliabilityTrialCount)

    for trial in 1...reliabilityTrialCount {
        let report = try runReliabilityChild(binary: binary, trial: trial, forced: false)
        reports.append(report)

        #expect(report.embeddingStatus == "active", "trial \(trial) status \(report.embeddingStatus)")
        #expect(report.dimensions == 384, "trial \(trial) dimensions \(report.dimensions)")
        #expect(report.allFinite, "trial \(trial) produced a non-finite embedding")
        #expect(report.paraphraseCorrect, "trial \(trial) missed the oolong paraphrase")
        #expect(
            report.initElapsedSeconds < reliabilityOpenLimitSeconds,
            "trial \(trial) open took \(report.initElapsedSeconds)s"
        )
    }

    try writeEvidenceReport(reports)
    #expect(reports.count == reliabilityTrialCount)
}

@Test
func builtInEmbeddingAutomaticOptionsBoundSetupWithoutWeakeningDefault() {
    #expect(BuiltInEmbeddingProviderOptions.automatic.timeoutSeconds == 15)
    #expect(BuiltInEmbeddingProviderOptions.automatic.batchSize == 1)
    #expect(BuiltInEmbeddingProviderOptions.automatic.prewarmBatchSize == 1)
    #expect(BuiltInEmbeddingProviderOptions.automatic.computeUnitsOrder == [
        .cpuAndNeuralEngine,
        .cpuOnly,
        .cpuAndGPU,
        .all,
    ])
    #expect(BuiltInEmbeddingProviderOptions.default.timeoutSeconds == 120)
}

@Test
func memoryStatsExposeEmbeddingStatusForAutomaticAndDisabled() async throws {
    try await TempFiles.withTempFile { url in
        let memory = try await Memory(at: url)
        let stats = await memory.stats()
        #expect(stats.embeddingStatus == .active(identity: stats.embedderIdentity))
        #expect(stats.queryEmbedderConfigured)
        try await memory.close()
    }

    try await TempFiles.withTempFile { url in
        let memory = try await Memory(
            at: url,
            config: .init(
                enableVectorSearch: false,
                requireOnDeviceProviders: false
            )
        )
        let stats = await memory.stats()
        #expect(stats.embeddingStatus == .disabled)
        try await memory.close()
    }
}
}

private struct ReliabilityChildReport: Codable, Sendable {
    var trial: Int
    var initElapsedSeconds: Double
    var searchElapsedSeconds: Double
    var embeddingStatus: String
    var identityProvider: String?
    var identityModel: String?
    var dimensions: Int
    var allFinite: Bool
    var paraphraseCorrect: Bool
}

private enum ReliabilityHarnessError: Error, CustomStringConvertible {
    case notFound([URL])
    case childFailed(status: Int32, stdout: String, stderr: String)
    case invalidJSON(String)

    var description: String {
        switch self {
        case .notFound(let candidates):
            return "Could not find WaxMiniLMReliabilityHarness. Tried:\n\(candidates.map(\.path).joined(separator: "\n"))"
        case .childFailed(let status, let stdout, let stderr):
            return "child failed status=\(status)\nstdout:\n\(stdout)\nstderr:\n\(stderr)"
        case .invalidJSON(let raw):
            return "child JSON was invalid:\n\(raw)"
        }
    }
}

private func runReliabilityChild(binary: URL, trial: Int, forced: Bool) throws -> ReliabilityChildReport {
    let process = Process()
    process.executableURL = binary
    process.arguments = ["--trial", String(trial)]
    var environment = ProcessInfo.processInfo.environment
    if forced {
        environment["WAX_MINILM_RELIABILITY_FORCED"] = "1"
    } else {
        environment.removeValue(forKey: "WAX_MINILM_RELIABILITY_FORCED")
    }
    process.environment = environment

    let stdoutPipe = Pipe()
    let stderrPipe = Pipe()
    process.standardOutput = stdoutPipe
    process.standardError = stderrPipe

    try process.run()
    process.waitUntilExit()

    let stdout = String(data: stdoutPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    let stderr = String(data: stderrPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    guard process.terminationStatus == 0 else {
        throw ReliabilityHarnessError.childFailed(
            status: process.terminationStatus,
            stdout: stdout,
            stderr: stderr
        )
    }

    let payload = stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    guard let data = payload.data(using: .utf8) else {
        throw ReliabilityHarnessError.invalidJSON(payload)
    }
    do {
        return try JSONDecoder().decode(ReliabilityChildReport.self, from: data)
    } catch {
        throw ReliabilityHarnessError.invalidJSON(payload)
    }
}

private func writeEvidenceReport(_ reports: [ReliabilityChildReport]) throws {
    let directory = evidenceReportPath.deletingLastPathComponent()
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    let data = try encoder.encode(reports)
    try data.write(to: evidenceReportPath)
}

private func reliabilityHarnessURL() throws -> URL {
    let env = ProcessInfo.processInfo.environment
    if let override = env["WAX_MINILM_RELIABILITY_HARNESS"], !override.isEmpty {
        return URL(fileURLWithPath: override)
    }

    let packageRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
    let candidates = [
        packageRoot
            .appendingPathComponent(".build")
            .appendingPathComponent("arm64-apple-macosx")
            .appendingPathComponent("debug")
            .appendingPathComponent("WaxMiniLMReliabilityHarness"),
        packageRoot
            .appendingPathComponent(".build")
            .appendingPathComponent("debug")
            .appendingPathComponent("WaxMiniLMReliabilityHarness"),
    ]
    for candidate in candidates where FileManager.default.isExecutableFile(atPath: candidate.path) {
        return candidate
    }
    throw ReliabilityHarnessError.notFound(candidates)
}
