import Foundation
import WaxCore
import WaxVectorSearch

/// How a reranked window of candidates is ordered.
public enum RerankingFusion: Sendable, Equatable {
    /// Order the candidates by reranker score alone. Ties keep the retrieval order.
    case rerankerOrder
    /// Reciprocal-rank fusion of the retrieval rank and the reranker rank: each candidate
    /// scores `1/(k + retrievalRank) + 1/(k + rerankerRank)` (ranks start at 1), and ties keep
    /// the retrieval order. A smaller `k` lets either ranking move a candidate further.
    case reciprocalRank(k: Int)
}

/// Options for reranking a search's top candidates.
public struct RerankingOptions: Sendable, Equatable {
    /// Bounds applied to ``candidateCount``.
    public static let candidateCountRange: ClosedRange<Int> = 1...200

    /// How many of the top retrieval candidates are rescored. Candidates below this
    /// window keep their retrieval order, after the reranked ones. Clamped to
    /// ``candidateCountRange``. The search fetches at least this many candidates even when
    /// ``Memory/SearchOptions/topK`` is smaller, so reranking can promote a candidate into
    /// the returned results.
    public var candidateCount: Int {
        didSet { candidateCount = Self.clampCandidateCount(candidateCount) }
    }

    /// How reranker scores and the retrieval order combine. A negative `k` is clamped to 0.
    public var fusion: RerankingFusion {
        didSet { fusion = Self.clampFusion(fusion) }
    }

    /// The defaults are the best setting measured with the built-in reranker on
    /// LongMemEval-S and LoCoMo: 20 candidates, reciprocal-rank fusion with `k = 10`.
    public init(candidateCount: Int = 20, fusion: RerankingFusion = .reciprocalRank(k: 10)) {
        self.candidateCount = Self.clampCandidateCount(candidateCount)
        self.fusion = Self.clampFusion(fusion)
    }

    public static let `default` = RerankingOptions()

    private static func clampCandidateCount(_ value: Int) -> Int {
        min(max(value, candidateCountRange.lowerBound), candidateCountRange.upperBound)
    }

    private static func clampFusion(_ fusion: RerankingFusion) -> RerankingFusion {
        guard case .reciprocalRank(let k) = fusion, k < 0 else { return fusion }
        return .reciprocalRank(k: 0)
    }
}

/// Built-in on-device rerankers.
public enum BuiltInReranker: String, CaseIterable, Sendable, Equatable, Codable {
    /// `cross-encoder/ms-marco-MiniLM-L-6-v2` (22 MB, INT8 weights): Core ML on Apple platforms,
    /// Wax's CPU interpreter on Linux. A document longer than one 288-token window is scored as
    /// the maximum over overlapping windows. Requires the `MiniLMReranker` package trait, and
    /// iOS 18 / macOS 15 on Apple platforms.
    case msMarcoMiniLM = "ms-marco-minilm-l6"
}

/// Errors thrown while constructing built-in rerankers.
public enum BuiltInRerankerError: LocalizedError, Sendable, Equatable {
    /// The reranker is unavailable in the current build or platform.
    case unavailable(BuiltInReranker)
    /// The reranker's model did not load within the timeout.
    case timedOut(BuiltInReranker)

    public var errorDescription: String? {
        switch self {
        case .unavailable(let reranker):
            #if canImport(CoreML)
            "\(reranker.rawValue) reranking is unavailable: it requires iOS 18/macOS 15 or later and the `MiniLMReranker` package trait."
            #else
            "\(reranker.rawValue) reranking is unavailable: it requires the `MiniLMReranker` package trait."
            #endif
        case .timedOut(let reranker):
            "\(reranker.rawValue) reranking timed out while loading its model."
        }
    }
}

/// Factory for Wax's built-in rerankers.
public enum BuiltInRerankers {
    /// Loads a built-in reranker. Loads are cached per compute unit for the process, so
    /// several stores share one model.
    ///
    /// Pass the result to ``Memory/RerankingSource/custom(_:_:)`` to pick a compute unit
    /// other than the CPU. ``Memory/RerankingSource/builtIn(_:_:)`` uses `.cpuOnly`.
    public static func make(
        _ reranker: BuiltInReranker,
        computeUnit: BuiltInEmbeddingComputeUnit = .cpuOnly,
        timeoutSeconds: Double = 120
    ) async throws -> any RerankingProvider {
        let timeout = Duration.milliseconds(Int64((timeoutSeconds > 0 ? timeoutSeconds : 120) * 1_000))
        return try await BuiltInRerankerCompiler.compile(reranker, computeUnit: computeUnit, timeout: timeout)
    }
}

extension Memory {
    /// Selects the reranker, if any, that reorders a search's top candidates.
    public enum RerankingSource: Sendable {
        /// No reranking (the default): search results keep their retrieval order.
        case disabled
        /// Use one of Wax's built-in rerankers on the CPU. Store creation throws
        /// ``BuiltInRerankerError`` if it cannot load (trait compiled out, unsupported OS).
        case builtIn(BuiltInReranker, RerankingOptions = .default)
        /// Use a custom reranker, or a built-in one from ``BuiltInRerankers/make(_:computeUnit:timeoutSeconds:)``.
        case custom(any RerankingProvider, RerankingOptions = .default)
    }
}
