import Foundation
import Testing
@testable import Wax

// MARK: - ImportanceScorer Tests

@Test func freshFrameHasAgeComponentNearOne() {
    let scorer = ImportanceScorer()
    let nowMs: Int64 = 1_700_000_000_000
    let result = scorer.score(frameTimestamp: nowMs, accessStats: nil, nowMs: nowMs)
    // exp(0) = 1.0 exactly
    #expect(abs(result.ageComponent - 1.0) < 0.001)
}

@Test func oneWeekOldFrameHasAgeComponentNearExpMinusOne() {
    let scorer = ImportanceScorer()
    let nowMs: Int64 = 1_700_000_000_000
    let oneWeekMs: Int64 = 168 * 60 * 60 * 1000
    let frameTimestamp = nowMs - oneWeekMs
    let result = scorer.score(frameTimestamp: frameTimestamp, accessStats: nil, nowMs: nowMs)
    // ageHalfLifeHours defaults to 168; exp(-168/168) = exp(-1) ~= 0.3679
    #expect(abs(result.ageComponent - Float(exp(-1.0))) < 0.01)
}

@Test func noAccessStatsYieldsZeroFrequencyAndRecency() {
    let scorer = ImportanceScorer()
    let nowMs: Int64 = 1_700_000_000_000
    let result = scorer.score(frameTimestamp: nowMs, accessStats: nil, nowMs: nowMs)
    #expect(result.frequencyComponent == 0.0)
    #expect(result.recencyComponent == 0.0)
}

@Test func withAccessStatsProducesNonZeroFrequencyAndRecency() {
    let scorer = ImportanceScorer()
    let nowMs: Int64 = 1_700_000_000_000
    var stats = FrameAccessStats(frameId: 1, nowMs: nowMs)
    // Record 9 additional accesses so accessCount = 10
    for _ in 0..<9 {
        stats.recordAccess(nowMs: nowMs)
    }
    let result = scorer.score(frameTimestamp: nowMs, accessStats: stats, nowMs: nowMs)
    #expect(result.frequencyComponent > 0.0)
    #expect(result.recencyComponent > 0.0)
}

@Test func zeroTotalWeightsFallsBackToAgeOnly() {
    let config = ImportanceScoringConfig(
        ageWeight: 0.0,
        frequencyWeight: 0.0,
        recencyWeight: 0.0,
        ageHalfLifeHours: 168,
        recencyHalfLifeHours: 24
    )
    let scorer = ImportanceScorer(config: config)
    let nowMs: Int64 = 1_700_000_000_000
    let result = scorer.score(frameTimestamp: nowMs, accessStats: nil, nowMs: nowMs)
    // Fallback to ageComponent, which is exp(0) = 1.0 for fresh frame
    #expect(abs(result.score - 1.0) < 0.001)
}

@Test func scoreAlwaysInZeroToOneRange() {
    let scorer = ImportanceScorer()
    let nowMs: Int64 = 1_700_000_000_000
    let testCases: [(Int64, FrameAccessStats?)] = [
        // Fresh frame, no stats
        (nowMs, nil),
        // Very old frame, no stats
        (nowMs - 365 * 24 * 60 * 60 * 1000, nil),
        // Fresh frame with stats
        (nowMs, FrameAccessStats(frameId: 1, nowMs: nowMs)),
        // Old frame with stats
        (nowMs - 30 * 24 * 60 * 60 * 1000, FrameAccessStats(frameId: 2, nowMs: nowMs - 7 * 24 * 60 * 60 * 1000)),
    ]
    for (timestamp, stats) in testCases {
        let result = scorer.score(frameTimestamp: timestamp, accessStats: stats, nowMs: nowMs)
        #expect(result.score >= 0.0)
        #expect(result.score <= 1.0)
    }
}

// MARK: - QueryAnalyzer Tests

@Test func simpleLowercaseQueryHasNoEntitiesAndLowSpecificity() {
    let analyzer = QueryAnalyzer()
    let signals = analyzer.analyze(query: "hello world")
    #expect(!signals.hasSpecificEntities)
    #expect(signals.specificityScore < 0.3)
}

@Test func queryWithNumbersHasSpecificEntities() {
    let analyzer = QueryAnalyzer()
    let signals = analyzer.analyze(query: "meeting at 3pm")
    #expect(signals.hasSpecificEntities)
}

@Test func queryWithCapitalizedWordsHasSpecificEntities() {
    let analyzer = QueryAnalyzer()
    let signals = analyzer.analyze(query: "John went home")
    #expect(signals.hasSpecificEntities)
}

@Test func queryWithQuotesHasQuotedPhrases() {
    let analyzer = QueryAnalyzer()
    let signals = analyzer.analyze(query: "search for \"exact phrase\"")
    #expect(signals.hasQuotedPhrases)
}

@Test func longQueryHasHigherSpecificityThanShort() {
    let analyzer = QueryAnalyzer()
    let short = analyzer.analyze(query: "hello world")
    let long = analyzer.analyze(query: "what did we discuss in the team meeting about deployment")
    #expect(long.specificityScore > short.specificityScore)
}

@Test func emptyStringHasZeroWordCount() {
    let analyzer = QueryAnalyzer()
    let signals = analyzer.analyze(query: "")
    #expect(signals.wordCount == 0)
}

@Test func normalizedTermsRemovesStopWordsAndNormalizesInflections() {
    let analyzer = QueryAnalyzer()
    let terms = analyzer.normalizedTerms(query: "Which city did Person01 move to in 2026?")
    #expect(terms.contains("city"))
    #expect(terms.contains("person01"))
    #expect(terms.contains("move"))
    #expect(terms.contains("2026"))
    #expect(!terms.contains("which"))
    #expect(!terms.contains("to"))
}

@Test func detectIntentFlagsOwnershipDateAndMultiHop() {
    let analyzer = QueryAnalyzer()
    let intent = analyzer.detectIntent(
        query: "For Atlas-01, who owns deployment readiness and what is the public launch date?"
    )
    #expect(intent.contains(.asksOwnership))
    #expect(intent.contains(.asksDate))
    #expect(intent.contains(.multiHop))
}

@Test func detectIntentFlagsLocationForMovedFormsWithoutWhereOrCity() {
    let analyzer = QueryAnalyzer()
    let movedIntent = analyzer.detectIntent(query: "Noah moved to Boise in 2021")
    let movingIntent = analyzer.detectIntent(query: "Noah is moving to Boise next month")

    #expect(movedIntent.contains(.asksLocation))
    #expect(movingIntent.contains(.asksLocation))
}

// MARK: - SurrogateTierSelector Tests

@Test func disabledPolicyAlwaysReturnsFull() {
    let selector = SurrogateTierSelector(policy: .disabled)
    let context = TierSelectionContext(
        frameTimestamp: 0,
        nowMs: 1_700_000_000_000
    )
    #expect(selector.selectTier(context: context) == .full)
}

@Test func ageOnlyRecentFrameReturnsFull() {
    let thresholds = AgeThresholds(recentDays: 7, oldDays: 30)
    let selector = SurrogateTierSelector(policy: .ageOnly(thresholds))
    let nowMs: Int64 = 1_700_000_000_000
    // Frame is 1 day old (well within 7 day "recent" threshold)
    let oneDayMs: Int64 = 1 * 24 * 60 * 60 * 1000
    let context = TierSelectionContext(
        frameTimestamp: nowMs - oneDayMs,
        nowMs: nowMs
    )
    #expect(selector.selectTier(context: context) == .full)
}

@Test func ageOnlyMidAgeFrameReturnsGist() {
    let thresholds = AgeThresholds(recentDays: 7, oldDays: 30)
    let selector = SurrogateTierSelector(policy: .ageOnly(thresholds))
    let nowMs: Int64 = 1_700_000_000_000
    // Frame is 14 days old (between 7 and 30)
    let fourteenDaysMs: Int64 = 14 * 24 * 60 * 60 * 1000
    let context = TierSelectionContext(
        frameTimestamp: nowMs - fourteenDaysMs,
        nowMs: nowMs
    )
    #expect(selector.selectTier(context: context) == .gist)
}

@Test func ageOnlyOldFrameReturnsMicro() {
    let thresholds = AgeThresholds(recentDays: 7, oldDays: 30)
    let selector = SurrogateTierSelector(policy: .ageOnly(thresholds))
    let nowMs: Int64 = 1_700_000_000_000
    // Frame is 60 days old (beyond 30 day threshold)
    let sixtyDaysMs: Int64 = 60 * 24 * 60 * 60 * 1000
    let context = TierSelectionContext(
        frameTimestamp: nowMs - sixtyDaysMs,
        nowMs: nowMs
    )
    #expect(selector.selectTier(context: context) == .micro)
}

@Test func importanceHighScoreReturnsFull() {
    let thresholds = ImportanceThresholds(fullThreshold: 0.6, gistThreshold: 0.3)
    // Use age-only weights so a fresh frame scores 1.0 (above fullThreshold)
    let config = ImportanceScoringConfig(
        ageWeight: 1.0,
        frequencyWeight: 0.0,
        recencyWeight: 0.0
    )
    let selector = SurrogateTierSelector(
        policy: .importance(thresholds),
        scorer: ImportanceScorer(config: config)
    )
    let nowMs: Int64 = 1_700_000_000_000
    // Fresh frame => ageComponent = 1.0 => score = 1.0 => full
    let context = TierSelectionContext(
        frameTimestamp: nowMs,
        nowMs: nowMs
    )
    #expect(selector.selectTier(context: context) == .full)
}

@Test func importanceLowScoreReturnsMicro() {
    let thresholds = ImportanceThresholds(fullThreshold: 0.6, gistThreshold: 0.3)
    let selector = SurrogateTierSelector(policy: .importance(thresholds))
    let nowMs: Int64 = 1_700_000_000_000
    // Frame is 2 years old, no access stats => very low importance
    let twoYearsMs: Int64 = 730 * 24 * 60 * 60 * 1000
    let context = TierSelectionContext(
        frameTimestamp: nowMs - twoYearsMs,
        nowMs: nowMs
    )
    #expect(selector.selectTier(context: context) == .micro)
}

@Test func queryBoostCanPromoteTier() {
    // Use importance thresholds where a mid-age frame sits just below .full
    let thresholds = ImportanceThresholds(fullThreshold: 0.6, gistThreshold: 0.3)
    let nowMs: Int64 = 1_700_000_000_000
    // Frame ~5 days old: ageComponent = exp(-120/168) ~= 0.49
    // With default weights (0.3 age, 0.4 freq, 0.3 recency) and no stats,
    // freq/recency = 0, so score = 0.3 * 0.49 / 1.0 ~= 0.147 (gist range without boost if thresholds changed)
    //
    // Instead use a frame that yields a score just below fullThreshold.
    // Age ~3.5 days: ageComponent = exp(-84/168) = exp(-0.5) ~= 0.6065
    // score = 0.3 * 0.6065 / 1.0 ~= 0.182 (micro range)
    //
    // Let's use custom scorer weights to get predictable results:
    let config = ImportanceScoringConfig(
        ageWeight: 1.0,
        frequencyWeight: 0.0,
        recencyWeight: 0.0,
        ageHalfLifeHours: 168,
        recencyHalfLifeHours: 24
    )
    let customSelector = SurrogateTierSelector(
        policy: .importance(thresholds),
        scorer: ImportanceScorer(config: config),
        queryBoostFactor: 0.3
    )
    // Frame ~90 hours old: ageComponent = exp(-90/168) ~= 0.585 (just below 0.6 full threshold)
    let ninetyHoursMs: Int64 = 90 * 60 * 60 * 1000
    let contextWithoutQuery = TierSelectionContext(
        frameTimestamp: nowMs - ninetyHoursMs,
        nowMs: nowMs
    )
    // Without query boost: score ~= 0.585 < 0.6 => gist
    #expect(customSelector.selectTier(context: contextWithoutQuery) == .gist)

    // With a specific query (specificityScore ~= 0.75), boost = 0.75 * 0.3 = 0.225
    // boosted score ~= 0.585 + 0.225 = 0.81 => full
    let querySignals = QuerySignals(
        hasSpecificEntities: true,
        wordCount: 10,
        hasQuotedPhrases: true,
        specificityScore: 0.75
    )
    let contextWithQuery = TierSelectionContext(
        frameTimestamp: nowMs - ninetyHoursMs,
        querySignals: querySignals,
        nowMs: nowMs
    )
    #expect(customSelector.selectTier(context: contextWithQuery) == .full)
}

@Test func extractTierFromValidJSON() {
    let tiers = SurrogateTiers(
        full: "This is the full detailed surrogate text.",
        gist: "A shorter gist version.",
        micro: "topic: meetings"
    )
    let data = try! JSONEncoder().encode(tiers)

    #expect(SurrogateTierSelector.extractTier(from: data, tier: .full) == "This is the full detailed surrogate text.")
    #expect(SurrogateTierSelector.extractTier(from: data, tier: .gist) == "A shorter gist version.")
    #expect(SurrogateTierSelector.extractTier(from: data, tier: .micro) == "topic: meetings")
}

@Test func extractTierFromPlainTextFallsBackForAnyTier() {
    let plainText = "Legacy single-tier surrogate content"
    let data = plainText.data(using: .utf8)!

    // All tiers should return the plain text as fallback
    #expect(SurrogateTierSelector.extractTier(from: data, tier: .full) == plainText)
    #expect(SurrogateTierSelector.extractTier(from: data, tier: .gist) == plainText)
    #expect(SurrogateTierSelector.extractTier(from: data, tier: .micro) == plainText)
}
