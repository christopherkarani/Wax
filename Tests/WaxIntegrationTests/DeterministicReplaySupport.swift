import Foundation

enum ReplayAction: String, Codable {
    case ingest
    case recall
}

struct ReplayStep: Codable, Sendable, Equatable {
    let action: ReplayAction
    let payload: String
}

struct ReplayPlan: Codable, Sendable, Equatable {
    let name: String
    let seed: UInt64
    let steps: [ReplayStep]
}

enum DeterministicReplaySupport {
    static func loadOrGeneratePlan(
        name: String,
        defaultSeed: UInt64,
        defaultIterations: Int
    ) throws -> ReplayPlan {
        let env = ProcessInfo.processInfo.environment
        if let replayPath = env["WAX_REPLAY_PATH"], !replayPath.isEmpty {
            let data = try Data(contentsOf: URL(fileURLWithPath: replayPath))
            return try JSONDecoder().decode(ReplayPlan.self, from: data)
        }

        let seed = env["WAX_REPLAY_SEED"].flatMap(UInt64.init) ?? defaultSeed
        let iterations = max(1, env["WAX_REPLAY_ITERATIONS"].flatMap(Int.init) ?? defaultIterations)
        let plan = generate(name: name, seed: seed, iterations: iterations)

        if let recordPath = env["WAX_REPLAY_RECORD_PATH"], !recordPath.isEmpty {
            let url = URL(fileURLWithPath: recordPath)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(plan).write(to: url, options: .atomic)
        }

        return plan
    }

    static func generate(name: String, seed: UInt64, iterations: Int) -> ReplayPlan {
        var state = seed
        let topics = [
            "swift",
            "vector",
            "memory",
            "wal",
            "replay",
            "compaction",
            "deterministic",
            "latency",
            "checksum",
        ]

        func next() -> UInt64 {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return state
        }

        var steps: [ReplayStep] = []
        steps.reserveCapacity(iterations)
        var ingestCount = 0

        for index in 0..<iterations {
            let value = next()
            let topic = topics[Int(value % UInt64(topics.count))]
            let chooseRecall = ingestCount > 0 && (value % 4 == 0)
            if chooseRecall {
                steps.append(ReplayStep(action: .recall, payload: topic))
            } else {
                let text = "doc-\(index) topic=\(topic) seed=\(value)"
                steps.append(ReplayStep(action: .ingest, payload: text))
                ingestCount += 1
            }
        }

        return ReplayPlan(name: name, seed: seed, steps: steps)
    }
}
