import ArgumentParser
import Foundation
import Wax
import WaxCore

struct StoreOptions: ParsableArguments {
    @Option(name: .customLong("store-path"), help: "Path to Wax memory store (.wax)")
    var storePath: String = StoreSession.defaultStorePath

    @Flag(name: .customLong("direct-store"), help: "Bypass the local broker and open the store file directly")
    var directStore: Bool = false

    @Flag(name: .customLong("no-embedder"), help: "Disable MiniLM embedder (text-only search)")
    var noEmbedder: Bool = false

    @Option(name: .customLong("format"), help: "Output format: json (default) or text")
    var format: OutputFormat = .json
}

enum EmbedderChoice: String, CaseIterable, ExpressibleByArgument, Sendable {
    case minilm
    case arctic
}

struct VectorStoreOptions: ParsableArguments {
    @OptionGroup var base: StoreOptions

    @OptionGroup var runtime: EmbedderRuntimeOptions

    @Option(name: .customLong("embedder"), help: "Embedder to use: minilm (default) or arctic")
    var embedder: EmbedderChoice = .minilm

    @Flag(
        name: .customLong("require-vector"),
        help: "Fail if vector search is unavailable instead of falling back to text-only mode"
    )
    var requireVector = false

    var storePath: String { base.storePath }
    var directStore: Bool { base.directStore }
    var noEmbedder: Bool { base.noEmbedder }
    var format: OutputFormat { base.format }
    var embedderTuning: CommandLineEmbedderRuntimeTuning {
        runtime.resolvedTuning()
    }

    func validate() throws {
        try runtime.validateRuntimeOptions()
    }
}

struct EmbedderRuntimeOptions: ParsableArguments {
    @Option(
        name: .customLong("embedder-compute-unit"),
        parsing: .upToNextOption,
        help: "Preferred Core ML compute unit in fallback order. Repeat to provide multiple values."
    )
    var computeUnits: [String] = []

    @Option(
        name: .customLong("embedder-batch-size"),
        help: "Batch size for command-line embedding workloads (default 1)."
    )
    var batchSize: Int?

    @Option(
        name: .customLong("embedder-prewarm-batch-size"),
        help: "Batch size to use during model prewarm when prewarm is enabled (default 1)."
    )
    var prewarmBatchSize: Int?

    @Option(
        name: .customLong("embedder-low-precision-gpu"),
        help: "Allow low-precision accumulation on GPU when supported (true or false)."
    )
    var allowLowPrecisionGPU: Bool?

    @Option(
        name: .customLong("embedder-timeout-secs"),
        help: "Timeout for embedder initialization in seconds."
    )
    var timeoutSeconds: Double?

    func validateRuntimeOptions() throws {
        for raw in computeUnits {
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty,
                  CommandLineEmbedderComputeUnit(rawValue: trimmed) != nil
            else {
                throw ValidationError("Invalid --embedder-compute-unit '\(raw)'")
            }
        }
        if let batchSize, batchSize <= 0 {
            throw ValidationError("--embedder-batch-size must be greater than zero")
        }
        if let prewarmBatchSize, prewarmBatchSize <= 0 {
            throw ValidationError("--embedder-prewarm-batch-size must be greater than zero")
        }
        if let timeoutSeconds, timeoutSeconds <= 0 {
            throw ValidationError("--embedder-timeout-secs must be greater than zero")
        }
    }

    func resolvedTuning(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> CommandLineEmbedderRuntimeTuning {
        var tuning = CommandLineEmbedderRuntimeTuning.fromEnvironment(environment)
        let parsedComputeUnits = computeUnits.compactMap {
            CommandLineEmbedderComputeUnit(rawValue: $0.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        if !parsedComputeUnits.isEmpty {
            tuning.computeUnitsOrder = parsedComputeUnits
        }
        if let batchSize, batchSize > 0 {
            tuning.batchSize = batchSize
        }
        if let prewarmBatchSize, prewarmBatchSize > 0 {
            tuning.prewarmBatchSize = prewarmBatchSize
        }
        if let allowLowPrecisionGPU {
            tuning.allowLowPrecisionGPU = allowLowPrecisionGPU
        }
        if let timeoutSeconds, timeoutSeconds > 0 {
            tuning.timeoutSeconds = timeoutSeconds
        }
        return tuning
    }
}
