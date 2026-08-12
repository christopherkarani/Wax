import Foundation
import WaxCore
import WaxVectorSearch

/// Built-in Wax embedding providers that can be used without going through the CLI or MCP server.
public enum BuiltInEmbeddingProvider: String, CaseIterable, Sendable, Equatable, Codable {
    /// The all-MiniLM-L6-v2 CoreML embedding provider.
    case miniLM = "minilm"
    /// The Snowflake Arctic Embed Small CoreML embedding provider.
    case arctic

    package var commandLineChoice: String {
        rawValue
    }
}

/// CoreML compute-unit preference for built-in Wax embedders.
public enum BuiltInEmbeddingComputeUnit: String, CaseIterable, Sendable, Equatable, Codable {
    /// Run inference on the CPU only.
    case cpuOnly
    /// Prefer CPU and GPU execution.
    case cpuAndGPU
    /// Prefer CPU and Apple Neural Engine execution.
    case cpuAndNeuralEngine
    /// Allow CoreML to use all available compute units.
    case all

    package var commandLineValue: CommandLineEmbedderComputeUnit {
        switch self {
        case .cpuOnly:
            .cpuOnly
        case .cpuAndGPU:
            .cpuAndGPU
        case .cpuAndNeuralEngine:
            .cpuAndNeuralEngine
        case .all:
            .all
        }
    }
}

/// Runtime options for constructing built-in Wax embedding providers.
public struct BuiltInEmbeddingProviderOptions: Sendable, Equatable, Codable {
    public var batchSize: Int
    public var prewarmBatchSize: Int
    public var allowLowPrecisionGPU: Bool
    public var timeoutSeconds: Double
    public var computeUnitsOrder: [BuiltInEmbeddingComputeUnit]

    public init(
        batchSize: Int = 1,
        prewarmBatchSize: Int = 1,
        allowLowPrecisionGPU: Bool = true,
        timeoutSeconds: Double = 120.0,
        computeUnitsOrder: [BuiltInEmbeddingComputeUnit] = [
            .cpuAndNeuralEngine,
            .cpuOnly,
            .cpuAndGPU,
            .all,
        ]
    ) {
        self.batchSize = max(1, batchSize)
        self.prewarmBatchSize = max(1, prewarmBatchSize)
        self.allowLowPrecisionGPU = allowLowPrecisionGPU
        self.timeoutSeconds = timeoutSeconds > 0 ? timeoutSeconds : 120.0
        self.computeUnitsOrder = computeUnitsOrder.isEmpty
            ? [.cpuAndNeuralEngine, .cpuOnly, .cpuAndGPU, .all]
            : computeUnitsOrder
    }

    public static let `default` = BuiltInEmbeddingProviderOptions()

    /// Bounded options for ``Memory.EmbeddingSource/automatic`` setup.
    ///
    /// Forced ``Memory.EmbeddingSource/builtIn`` construction keeps ``default``
    /// (120s) unless the caller supplies its own options.
    public static let automatic = BuiltInEmbeddingProviderOptions(
        batchSize: 1,
        prewarmBatchSize: 1,
        timeoutSeconds: 15,
        computeUnitsOrder: [.cpuAndNeuralEngine, .cpuOnly, .cpuAndGPU, .all]
    )

    package var tuning: CommandLineEmbedderRuntimeTuning {
        CommandLineEmbedderRuntimeTuning(
            batchSize: batchSize,
            prewarmBatchSize: prewarmBatchSize,
            allowLowPrecisionGPU: allowLowPrecisionGPU,
            timeoutSeconds: timeoutSeconds,
            computeUnitsOrder: computeUnitsOrder.map(\.commandLineValue)
        )
    }
}

/// Errors thrown while constructing built-in Wax embedding providers.
public enum BuiltInEmbeddingProviderError: LocalizedError, Sendable, Equatable {
    /// The requested provider is unavailable in the current build or platform.
    case unavailable(BuiltInEmbeddingProvider)

    public var errorDescription: String? {
        switch self {
        case .unavailable(let provider):
            let requirement: String = switch provider {
            case .miniLM:
                "requires iOS 18/macOS 15 or later and the default `MiniLMEmbeddings` package trait"
            case .arctic:
                "requires iOS 18/macOS 15 or later and the `ArcticEmbeddings` package trait"
            }
            return "\(provider.rawValue) embeddings are unavailable: \(requirement). On older OS versions, pass a custom EmbeddingProvider or use text-only search."
        }
    }
}

/// Factory for Wax's built-in embedding providers.
public enum BuiltInEmbeddings {
    /// Construct a built-in embedding provider using Wax's on-device CoreML runtime.
    ///
    /// Construction is eager: the provider is loaded and probed once under
    /// ``BuiltInEmbeddingProviderOptions/timeoutSeconds``. Failures throw the
    /// underlying typed error rather than returning `nil`.
    public static func make(
        _ provider: BuiltInEmbeddingProvider,
        options: BuiltInEmbeddingProviderOptions = .default
    ) async throws -> any EmbeddingProvider {
        try await CommandLineEmbedderFactory.makeEagerEmbedder(
            provider: provider,
            tuning: options.tuning
        )
    }
}
