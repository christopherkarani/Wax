import Foundation
import WaxCore
import WaxTextSearch

// MARK: - Surrogate Tier Selection

/// Compression tier for surrogate retrieval
public enum SurrogateTier: String, Sendable, Equatable, CaseIterable {
    case full
    case gist
    case micro
}

/// Age thresholds for tier selection
public struct AgeThresholds: Sendable, Equatable {
    /// Memories newer than this use full tier (days)
    public var recentDays: Int
    /// Memories older than this use micro tier (days)
    public var oldDays: Int
    
    public init(recentDays: Int = 7, oldDays: Int = 30) {
        precondition(recentDays <= oldDays, "recentDays (\(recentDays)) must be <= oldDays (\(oldDays))")
        self.recentDays = recentDays
        self.oldDays = oldDays
    }
    
    public var recentMs: Int64 { Int64(recentDays) * 24 * 60 * 60 * 1000 }
    public var oldMs: Int64 { Int64(oldDays) * 24 * 60 * 60 * 1000 }
}

/// Importance score thresholds for tier selection
public struct ImportanceThresholds: Sendable, Equatable {
    /// Score >= this uses full tier
    public var fullThreshold: Float
    /// Score >= this uses gist tier (below = micro)
    public var gistThreshold: Float
    
    public init(fullThreshold: Float = 0.6, gistThreshold: Float = 0.3) {
        precondition(gistThreshold < fullThreshold, "gistThreshold (\(gistThreshold)) must be < fullThreshold (\(fullThreshold))")
        self.fullThreshold = fullThreshold
        self.gistThreshold = gistThreshold
    }
}

/// Policy for selecting which surrogate tier to use at retrieval time
public enum TierSelectionPolicy: Sendable, Equatable {
    /// Always use full tier (no compression based on age/importance)
    case disabled
    
    /// Select tier based on memory age only
    case ageOnly(AgeThresholds)
    
    /// Select tier based on importance (age + access frequency)
    case importance(ImportanceThresholds)
    
    /// Balanced age-only preset (7 days recent, 30 days old)
    public static let ageBalanced = TierSelectionPolicy.ageOnly(AgeThresholds())
    
    /// Balanced importance-based preset
    public static let importanceBalanced = TierSelectionPolicy.importance(ImportanceThresholds())
}

// MARK: - FastRAGConfig

/// Configuration for the FastRAG context builder, controlling token budgets, search parameters, and surrogate tier selection.
public struct FastRAGConfig: Sendable, Equatable {
    /// Assembly mode: fast (expansion + snippets) or denseCached (expansion + surrogates + snippets).
    public enum Mode: Sendable, Equatable {
        case fast
        case denseCached
    }

    public var mode: Mode = .fast

    /// Total token budget for the returned context (snippets + expansion).
    public var maxContextTokens: Int = 1_500

    /// Token budget for the single "expanded" item.
    public var expansionMaxTokens: Int = 600

    /// Hard cap on expansion bytes before UTF-8 decode/tokenization.
    public var expansionMaxBytes: Int = 2 * 1024 * 1024

    /// Per-snippet token cap to avoid one snippet consuming the entire budget.
    public var snippetMaxTokens: Int = 200

    /// Max snippet items included (after expansion).
    public var maxSnippets: Int = 24

    /// Max surrogate items included (after expansion) when `mode == .denseCached`.
    public var maxSurrogates: Int = 8

    /// Per-surrogate token cap when `mode == .denseCached`.
    public var surrogateMaxTokens: Int = 60

    /// Search parameters used to collect candidates.
    public var searchTopK: Int = 24
    public var searchMode: SearchMode = .hybrid(alpha: 0.5)
    public var rrfK: Int = 60
    public var previewMaxBytes: Int = 512

    /// Enable deterministic query-aware reranking for context item ordering.
    public var enableAnswerFocusedRanking: Bool = true

    /// Max top candidates to rerank for answer-focused ordering.
    public var answerRerankWindow: Int = 12

    /// Penalty for distractor-like snippets during answer-focused ranking.
    public var answerDistractorPenalty: Float = 0.30
    
    // MARK: - Tier Selection
    
    /// Policy for selecting surrogate tier at retrieval time
    public var tierSelectionPolicy: TierSelectionPolicy = .importanceBalanced
    
    /// Enable query-aware tier selection (boosts tier for specific queries)
    public var enableQueryAwareTierSelection: Bool = true
    
    /// Optional fixed "now" timestamp used for deterministic tier selection.
    /// When nil, Wax uses wall clock time.
    public var deterministicNowMs: Int64? = nil

    public init(
        mode: Mode = .fast,
        maxContextTokens: Int = 1_500,
        expansionMaxTokens: Int = 600,
        expansionMaxBytes: Int = 2 * 1024 * 1024,
        snippetMaxTokens: Int = 200,
        maxSnippets: Int = 24,
        maxSurrogates: Int = 8,
        surrogateMaxTokens: Int = 60,
        searchTopK: Int = 24,
        searchMode: SearchMode = .hybrid(alpha: 0.5),
        rrfK: Int = 60,
        previewMaxBytes: Int = 512,
        enableAnswerFocusedRanking: Bool = true,
        answerRerankWindow: Int = 12,
        answerDistractorPenalty: Float = 0.30,
        tierSelectionPolicy: TierSelectionPolicy = .importanceBalanced,
        enableQueryAwareTierSelection: Bool = true,
        deterministicNowMs: Int64? = nil
    ) {
        self.mode = mode
        self.maxContextTokens = maxContextTokens
        self.expansionMaxTokens = expansionMaxTokens
        self.expansionMaxBytes = expansionMaxBytes
        self.snippetMaxTokens = snippetMaxTokens
        self.maxSnippets = maxSnippets
        self.maxSurrogates = maxSurrogates
        self.surrogateMaxTokens = surrogateMaxTokens
        self.searchTopK = searchTopK
        self.searchMode = searchMode
        self.rrfK = rrfK
        self.previewMaxBytes = previewMaxBytes
        self.enableAnswerFocusedRanking = enableAnswerFocusedRanking
        self.answerRerankWindow = answerRerankWindow
        self.answerDistractorPenalty = answerDistractorPenalty
        self.tierSelectionPolicy = tierSelectionPolicy
        self.enableQueryAwareTierSelection = enableQueryAwareTierSelection
        self.deterministicNowMs = deterministicNowMs
    }
}
