import Foundation
import Wax

@main
struct WaxMiniLMReliabilityHarness {
    private static let target = "The user's favorite beverage is oolong tea."
    private static let distractors = [
        "Swift 6.2 introduces improved concurrency.",
        "Async/await makes code more readable.",
        "The capital of France is Paris.",
    ]
    private static let paraphrase = "What does the person like to drink?"

    static func main() async {
        do {
            let trial = parseTrial(CommandLine.arguments)
            let report = try await runTrial(trial)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            let data = try encoder.encode(report)
            guard let json = String(data: data, encoding: .utf8) else {
                throw HarnessError.invalidJSON
            }
            print(json)
        } catch {
            FileHandle.standardError.write(Data("FAIL \(error)\n".utf8))
            Foundation.exit(1)
        }
    }

    private static func parseTrial(_ args: [String]) -> Int {
        if let index = args.firstIndex(of: "--trial") {
            let valueIndex = args.index(after: index)
            if valueIndex < args.endIndex, let value = Int(args[valueIndex]) {
                return value
            }
        }
        return 0
    }

    private static func runTrial(_ trial: Int) async throws -> Report {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("wax-minilm-reliability-\(trial)-\(UUID().uuidString)")
            .appendingPathExtension("wax")
        defer { try? FileManager.default.removeItem(at: url) }

        let initStart = ContinuousClock.now
        let memory: Memory
        if ProcessInfo.processInfo.environment["WAX_MINILM_RELIABILITY_FORCED"] == "1" {
            memory = try await Memory(at: url) { $0.embedding = .builtIn(.miniLM) }
        } else {
            memory = try await Memory(at: url)
        }
        let initElapsed = initStart.duration(to: .now)
        let stats = await memory.stats()

        if case .unavailable(let reason) = stats.embeddingStatus {
            throw HarnessError.setupFailed(
                status: statusString(stats.embeddingStatus),
                reason: reason,
                initElapsedSeconds: seconds(initElapsed)
            )
        }
        guard case .active = stats.embeddingStatus else {
            throw HarnessError.setupFailed(
                status: statusString(stats.embeddingStatus),
                reason: "expected active embedder",
                initElapsedSeconds: seconds(initElapsed)
            )
        }

        try await memory.save(target)
        for distractor in distractors {
            try await memory.save(distractor)
        }
        try await memory.flush()

        let searchStart = ContinuousClock.now
        let results = try await memory.search(
            paraphrase,
            options: .init(topK: 1, mode: .vectorOnly)
        )
        let searchElapsed = searchStart.duration(to: .now)

        let embedder = try await BuiltInEmbeddings.make(.miniLM)
        let vector = try await embedder.embed("wax reliability probe")

        let paraphraseCorrect = results.items.first?.text.contains("oolong tea") == true
            && results.items.first?.sources.contains(.vector) == true

        try await memory.close()

        return Report(
            trial: trial,
            initElapsedSeconds: seconds(initElapsed),
            searchElapsedSeconds: seconds(searchElapsed),
            embeddingStatus: statusString(stats.embeddingStatus),
            identityProvider: stats.embedderIdentity?.provider,
            identityModel: stats.embedderIdentity?.model,
            dimensions: vector.count,
            allFinite: vector.allSatisfy(\.isFinite) && vector.contains(where: { $0 != 0 }),
            paraphraseCorrect: paraphraseCorrect
        )
    }

    private static func statusString(_ status: EmbeddingStatus) -> String {
        switch status {
        case .active:
            return "active"
        case .disabled:
            return "disabled"
        case .unavailable(let reason):
            return "unavailable:\(reason)"
        }
    }

    private static func seconds(_ duration: Duration) -> Double {
        let components = duration.components
        return Double(components.seconds) + Double(components.attoseconds) / 1_000_000_000_000_000_000
    }

    private struct Report: Codable {
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

    private enum HarnessError: Error, CustomStringConvertible {
        case invalidJSON
        case setupFailed(status: String, reason: String, initElapsedSeconds: Double)

        var description: String {
            switch self {
            case .invalidJSON:
                return "invalid JSON encoding"
            case let .setupFailed(status, reason, initElapsedSeconds):
                return "setup \(status) after \(initElapsedSeconds)s: \(reason)"
            }
        }
    }
}
