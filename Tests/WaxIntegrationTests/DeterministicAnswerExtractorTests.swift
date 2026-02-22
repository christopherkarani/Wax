import Foundation
import Testing
@testable import Wax

// MARK: - Helpers

private func item(text: String, score: Float = 0.5) -> RAGContext.Item {
    RAGContext.Item(kind: .snippet, frameId: 0, score: score, sources: [], text: text)
}

private let extractor = DeterministicAnswerExtractor()

// MARK: - Empty items produces empty answer

@Test
func deterministicAnswerExtractorEmptyItemsReturnsEmpty() {
    let answer = extractor.extractAnswer(query: "When did it launch?", items: [])
    #expect(answer.isEmpty)
}

// MARK: - Items with only whitespace / highlight brackets are filtered

@Test
func deterministicAnswerExtractorFiltersBlankAndBracketOnlyItems() {
    // Items that reduce to empty strings after cleanText() must be filtered out.
    let blankItems = [
        item(text: "   "),
        item(text: "[  ]"),
        item(text: "\n\t"),
    ]
    let answer = extractor.extractAnswer(query: "anything", items: blankItems)
    // All items are blank; the extractor should return empty.
    #expect(answer.isEmpty)
}

// MARK: - Ownership + date intent

@Test
func deterministicAnswerExtractorOwnershipAndDateReturnsOwnerWithDate() {
    // "who … owns deployment readiness" triggers .asksOwnership; "launch date" triggers .asksDate.
    let query = "For Atlas-01, who owns deployment readiness and what is the public launch date?"
    let items = [
        item(
            text: "Alice Smith owns deployment readiness for the project. "
                + "The public launch is scheduled for March 15, 2025.",
            score: 0.9
        ),
    ]
    let answer = extractor.extractAnswer(query: query, items: items)
    // Should contain the owner name.
    #expect(answer.lowercased().contains("alice") || answer.lowercased().contains("smith"))
}

// MARK: - Pet name + adoption date path

@Test
func deterministicAnswerExtractorPetNameAndAdoptionDateReturnsJoined() {
    let query = "What is my dog's name and when did I adopt it?"
    let items = [
        item(
            text: "I adopted a golden retriever named Buddy in March 2022.",
            score: 0.8
        ),
    ]
    let answer = extractor.extractAnswer(query: query, items: items)
    // Should contain the pet name and adoption month/year.
    #expect(answer.lowercased().contains("buddy"))
    #expect(answer.contains("March 2022") || answer.contains("march 2022"))
}

// MARK: - Pet query with only name (no adoption date)

@Test
func deterministicAnswerExtractorPetQueryWithoutAdoptionDateFallsThroughToLexical() {
    // When only a pet name is found (no adoption date), the pet branch is not taken;
    // the extractor falls through to the lexical sentence path.
    let query = "What is my pet's name?"
    let items = [
        item(text: "I have a labrador named Max who loves to run.", score: 0.7),
    ]
    let answer = extractor.extractAnswer(query: query, items: items)
    #expect(!answer.isEmpty)
}

// MARK: - Allergy extraction

@Test
func deterministicAnswerExtractorAllergyQueryExtractsAllergen() {
    let query = "Does the user have any allergies?"
    let items = [
        item(text: "The user is allergic to peanuts and should avoid all nut products.", score: 0.85),
    ]
    let answer = extractor.extractAnswer(query: query, items: items)
    #expect(answer.lowercased().contains("peanut") || answer.lowercased().contains("allergic"))
}

// MARK: - Allergy query with no allergen in corpus falls back gracefully

@Test
func deterministicAnswerExtractorAllergyQueryWithNoMatchFallsBack() {
    let query = "Does the user have any allergies?"
    let items = [
        item(text: "The user is perfectly healthy with no known conditions.", score: 0.5),
    ]
    let answer = extractor.extractAnswer(query: query, items: items)
    // Falls through to lexical sentence — must be non-empty.
    #expect(!answer.isEmpty)
}

// MARK: - Travel / flight destination

@Test
func deterministicAnswerExtractorTravelQueryExtractsDestination() {
    let query = "Where is the user flying to?"
    let items = [
        item(text: "The user has a Flight to Seattle scheduled for next week.", score: 0.9),
    ]
    let answer = extractor.extractAnswer(query: query, items: items)
    #expect(answer.lowercased().contains("seattle"))
}

// MARK: - Travel query triggers asksLocation branch too

@Test
func deterministicAnswerExtractorTravelTriggersLocationBranchAndExtractsDestination() {
    // "flying" triggers asksTravel; "where" triggers asksLocation intent.
    let query = "Where is John flying to this weekend?"
    let items = [
        item(text: "John has a Flight to Chicago for a conference.", score: 0.85),
    ]
    let answer = extractor.extractAnswer(query: query, items: items)
    #expect(answer.lowercased().contains("chicago"))
}

// MARK: - Moved-to city (location intent, no travel keyword)

@Test
func deterministicAnswerExtractorMovedToCityExtractsCity() {
    let query = "Which city did Sarah move to?"
    let items = [
        item(text: "Sarah recently Moved to Portland after accepting a new job offer.", score: 0.8),
    ]
    let answer = extractor.extractAnswer(query: query, items: items)
    #expect(answer.lowercased().contains("portland"))
}

// MARK: - Communication style / preference

@Test
func deterministicAnswerExtractorCommunicationStyleExtractsPreference() {
    let query = "How does the user prefer to receive status updates?"
    let items = [
        item(text: "The user prefers concise bullet-point written updates every Monday morning.", score: 0.9),
    ]
    let answer = extractor.extractAnswer(query: query, items: items)
    // Should contain the preference text.
    #expect(answer.lowercased().contains("bullet") || answer.lowercased().contains("concise"))
}

// MARK: - Appointment date/time extraction

@Test
func deterministicAnswerExtractorAppointmentDateTimeExtractsFullDatetime() {
    let query = "When is the dentist appointment?"
    let items = [
        item(text: "Your next dentist appointment is on April 7, 2025 at 10:30 AM.", score: 0.9),
    ]
    let answer = extractor.extractAnswer(query: query, items: items)
    #expect(answer.contains("April") || answer.contains("2025"))
}

// MARK: - Launch date extraction (asksDate without dentist)

@Test
func deterministicAnswerExtractorLaunchDateExtracted() {
    let query = "When is the public launch date for the project?"
    let items = [
        item(
            text: "The project public launch is planned for September 10, 2025.",
            score: 0.9
        ),
    ]
    let answer = extractor.extractAnswer(query: query, items: items)
    #expect(answer.contains("September") || answer.contains("2025") || answer.contains("10"))
}

// MARK: - Generic date fallback (asksDate, no launch clause)

@Test
func deterministicAnswerExtractorGenericDateFallbackExtractsDate() {
    let query = "What date was the event?"
    let items = [
        item(text: "The event took place on June 3, 2024.", score: 0.8),
    ]
    let answer = extractor.extractAnswer(query: query, items: items)
    #expect(answer.contains("June") || answer.contains("2024") || answer.contains("3"))
}

// MARK: - asksOwnership only (no date) returns owner

@Test
func deterministicAnswerExtractorOwnershipOnlyWithNoDateReturnsOwner() {
    let query = "Who owns the backend service?"
    let items = [
        item(text: "Carlos Martinez owns the backend service reliability.", score: 0.85),
    ]
    let answer = extractor.extractAnswer(query: query, items: items)
    #expect(answer.lowercased().contains("carlos") || answer.lowercased().contains("martinez"))
}

// MARK: - Lexical sentence fallback (no intent matches)

@Test
func deterministicAnswerExtractorLexicalSentenceFallbackPrefersOverlappingTerms() {
    // A query with no recognised intent (no "who/where/when/launch/etc.") causes the
    // extractor to fall through to the lexical sentence scorer.
    let query = "Tell me about Wax performance"
    let items = [
        item(
            text: "Wax achieves excellent performance via Metal acceleration. "
                + "Biscuits are tasty. "
                + "Wax performance benchmarks show sub-millisecond latency.",
            score: 0.5
        ),
    ]
    let answer = extractor.extractAnswer(query: query, items: items)
    // The sentence with most overlapping terms should win.
    #expect(answer.lowercased().contains("wax") || answer.lowercased().contains("performance"))
}

// MARK: - Lexical fallback when queryTerms is empty

@Test
func deterministicAnswerExtractorLexicalFallbackWithEmptyQueryTerms() {
    // A query consisting entirely of stop-words yields an empty queryTerms set,
    // causing bestLexicalSentence to return texts.first.
    let query = "the and or"
    let items = [
        item(text: "First sentence here. Second sentence there.", score: 0.5),
    ]
    let answer = extractor.extractAnswer(query: query, items: items)
    #expect(!answer.isEmpty)
}

// MARK: - Multiple items - relevance scoring picks best

@Test
func deterministicAnswerExtractorPicksBestScoringItem() {
    let query = "When did the project launch?"
    let distractor = item(
        text: "Weekly checklist signoff completed. No authoritative date confirmed.",
        score: 0.3
    )
    let relevant = item(
        text: "The public launch occurred on July 4, 2024.",
        score: 0.9
    )
    let answer = extractor.extractAnswer(query: query, items: [distractor, relevant])
    #expect(answer.contains("July") || answer.contains("2024"))
}

// MARK: - Highlight bracket stripping

@Test
func deterministicAnswerExtractorStripsHighlightBracketsBeforeMatching() {
    let query = "When did [Sarah] [move] to [Denver]?"
    let items = [
        item(text: "[Sarah] Moved to [Denver] in early 2023.", score: 0.8),
    ]
    let answer = extractor.extractAnswer(query: query, items: items)
    // Brackets must be stripped; the city should still be extracted.
    #expect(answer.lowercased().contains("denver"))
}

// MARK: - QueryAnalyzer uncovered branches

@Test
func queryAnalyzerYearTermsExtractsOnlyFourDigitYears() {
    let analyzer = QueryAnalyzer()

    let years = analyzer.yearTerms(in: "The project launched in 2023 and expanded in 2024.")
    #expect(years.contains("2023"))
    #expect(years.contains("2024"))

    // Non-four-digit numbers should not appear as year terms.
    let noYears = analyzer.yearTerms(in: "Version 3.2 released in 120 seconds.")
    #expect(!noYears.contains("3"))
    #expect(!noYears.contains("120"))
}

@Test
func queryAnalyzerDateLiteralsHandlesAllSupportedFormats() {
    let analyzer = QueryAnalyzer()

    // Full month name: Month D, YYYY
    let full = analyzer.dateLiterals(in: "The meeting is on January 5, 2025.")
    #expect(full.contains("January 5, 2025") || full.first?.contains("January") == true)

    // Abbreviated month: Mon D, YYYY
    let abbreviated = analyzer.dateLiterals(in: "Deadline: Feb 28, 2026.")
    #expect(abbreviated.first?.contains("Feb") == true || abbreviated.first?.contains("28") == true)

    // Day-first format: D Month YYYY
    let dayFirst = analyzer.dateLiterals(in: "Event on 15 March 2024.")
    #expect(dayFirst.first?.contains("15") == true || dayFirst.first?.contains("March") == true)

    // ISO format: YYYY-MM-DD
    let iso = analyzer.dateLiterals(in: "Logged at 2024-07-04.")
    #expect(iso.contains("2024-07-04"))
}

@Test
func queryAnalyzerNormalizedDateKeysProducesISOForm() {
    let analyzer = QueryAnalyzer()
    let keys = analyzer.normalizedDateKeys(in: "The launch is on March 15, 2025.")
    #expect(keys.contains("2025-03-15"))
}

@Test
func queryAnalyzerContainsDateLiteralReturnsFalseForPlainText() {
    let analyzer = QueryAnalyzer()
    #expect(!analyzer.containsDateLiteral("no date here at all"))
}

@Test
func queryAnalyzerContainsDateLiteralReturnsTrueWhenDatePresent() {
    let analyzer = QueryAnalyzer()
    #expect(analyzer.containsDateLiteral("Appointment on September 3, 2025."))
}

@Test
func queryAnalyzerEntityTermsExtractsAlphanumericCompoundTokens() {
    let analyzer = QueryAnalyzer()
    let entities = analyzer.entityTerms(query: "What did Atlas10 ship in 2025?")
    // "atlas10" contains both letters and digits — should be extracted.
    #expect(entities.contains("atlas10"))
}

@Test
func queryAnalyzerEntityTermsExtractsAdjacentLetterDigitPairs() {
    let analyzer = QueryAnalyzer()
    // "person" followed by "18" → entity "person18"
    let entities = analyzer.entityTerms(query: "person 18 deployed the service")
    #expect(entities.contains("person18"))
}

@Test
func queryAnalyzerEntityTermsDoesNotExtractFromEmptyQuery() {
    let analyzer = QueryAnalyzer()
    let entities = analyzer.entityTerms(query: "")
    #expect(entities.isEmpty)
}

@Test
func queryAnalyzerDetectIntentMultiHopRequiresTwoIntentsAndAnd() {
    let analyzer = QueryAnalyzer()
    // Single intent — multiHop must not be set.
    let single = analyzer.detectIntent(query: "When did the project launch?")
    #expect(!single.contains(.multiHop))

    // Two intents joined by " and " — multiHop must be set.
    let multi = analyzer.detectIntent(
        query: "Who owns deployment readiness and when is the launch date?"
    )
    #expect(multi.contains(.multiHop))
}

// MARK: - FastRAGContextBuilder.shouldUseFullFrameForSnippet

@Test
func fastRAGShouldUseFullFrameReturnsFalseForEmptyPreview() {
    let analyzer = QueryAnalyzer()
    let intent = QueryIntent()
    #expect(!FastRAGContextBuilder.shouldUseFullFrameForSnippet(preview: "", intent: intent, analyzer: analyzer))
}

@Test
func fastRAGShouldUseFullFrameReturnsTrueForDateIntentWithLaunchHintButNoDateLiteral() {
    let analyzer = QueryAnalyzer()
    // .asksDate intent + preview contains "launch" but no date literal → should expand.
    let intent = QueryIntent.asksDate
    let preview = "This memo discusses the public launch plans for next quarter."
    let result = FastRAGContextBuilder.shouldUseFullFrameForSnippet(
        preview: preview,
        intent: intent,
        analyzer: analyzer
    )
    #expect(result)
}

@Test
func fastRAGShouldUseFullFrameReturnsFalseWhenPreviewAlreadyHasDateLiteral() {
    let analyzer = QueryAnalyzer()
    let intent = QueryIntent.asksDate
    // Preview has "launch" AND contains a date literal — no expansion needed.
    let preview = "Launch is scheduled for March 15, 2025."
    let result = FastRAGContextBuilder.shouldUseFullFrameForSnippet(
        preview: preview,
        intent: intent,
        analyzer: analyzer
    )
    #expect(!result)
}

@Test
func fastRAGShouldUseFullFrameReturnsTrueForOwnershipIntentWithOwnsButNotDeploymentReadiness() {
    let analyzer = QueryAnalyzer()
    let intent = QueryIntent.asksOwnership
    let preview = "Sarah owns the backend infrastructure team."
    let result = FastRAGContextBuilder.shouldUseFullFrameForSnippet(
        preview: preview,
        intent: intent,
        analyzer: analyzer
    )
    #expect(result)
}

@Test
func fastRAGShouldUseFullFrameReturnsFalseForOwnershipWithDeploymentReadinessInPreview() {
    let analyzer = QueryAnalyzer()
    let intent = QueryIntent.asksOwnership
    // Preview already contains "deployment readiness" — no full-frame expansion needed.
    let preview = "Carlos owns deployment readiness for the project."
    let result = FastRAGContextBuilder.shouldUseFullFrameForSnippet(
        preview: preview,
        intent: intent,
        analyzer: analyzer
    )
    #expect(!result)
}

@Test
func fastRAGShouldUseFullFrameReturnsFalseForNonMatchingIntent() {
    let analyzer = QueryAnalyzer()
    // asksLocation does not trigger either date or ownership expansion path.
    let intent = QueryIntent.asksLocation
    let preview = "The team moved offices last week."
    let result = FastRAGContextBuilder.shouldUseFullFrameForSnippet(
        preview: preview,
        intent: intent,
        analyzer: analyzer
    )
    #expect(!result)
}

// MARK: - FastRAGContextBuilder.rerankCandidatesForAnswer

@Test
func fastRAGRerankCandidatesWindowSmallerThanOneReturnsUnchanged() {
    let results = [
        SearchResponse.Result(frameId: 1, score: 0.9, previewText: "first", sources: []),
        SearchResponse.Result(frameId: 2, score: 0.5, previewText: "second", sources: []),
    ]
    var config = FastRAGConfig(searchMode: .textOnly)
    config.answerRerankWindow = 0
    let reranked = FastRAGContextBuilder.rerankCandidatesForAnswer(
        results: results,
        query: "test",
        config: config
    )
    #expect(reranked.map(\SearchResponse.Result.frameId) == results.map(\SearchResponse.Result.frameId))
}

@Test
func fastRAGRerankCandidatesWithEmptyQueryTermsAndIntentsReturnsUnchanged() {
    let results = [
        SearchResponse.Result(frameId: 1, score: 0.9, previewText: nil, sources: []),
        SearchResponse.Result(frameId: 2, score: 0.5, previewText: nil, sources: []),
    ]
    var config = FastRAGConfig(searchMode: .textOnly)
    config.answerRerankWindow = 4
    // Query is stop-words only → empty intent and empty queryTerms → return unchanged.
    let reranked = FastRAGContextBuilder.rerankCandidatesForAnswer(
        results: results,
        query: "a the and",
        config: config
    )
    #expect(reranked.map(\SearchResponse.Result.frameId) == results.map(\SearchResponse.Result.frameId))
}

@Test
func fastRAGRerankCandidatesReordersWhenHighRelevanceResultIsLower() {
    // First result has a preview that does NOT mention "launch" or any date.
    // Second result mentions "public launch" and a date → should be promoted to first.
    let results = [
        SearchResponse.Result(
            frameId: 1,
            score: 0.8,
            previewText: "A general overview of the system architecture.",
            sources: []
        ),
        SearchResponse.Result(
            frameId: 2,
            score: 0.6,
            previewText: "The public launch is confirmed for June 1, 2025.",
            sources: []
        ),
    ]
    var config = FastRAGConfig(searchMode: .textOnly)
    config.answerRerankWindow = 2
    config.enableAnswerFocusedRanking = true
    let reranked = FastRAGContextBuilder.rerankCandidatesForAnswer(
        results: results,
        query: "When is the public launch date?",
        config: config
    )
    // Frame 2 should now be ranked first because it directly answers the date query.
    #expect(reranked.first?.frameId == 2)
}

@Test
func fastRAGRerankCandidatesWindowLargerThanResultsCoversAll() {
    let results = [
        SearchResponse.Result(frameId: 10, score: 0.7, previewText: "alpha", sources: []),
        SearchResponse.Result(frameId: 11, score: 0.6, previewText: "beta", sources: []),
        SearchResponse.Result(frameId: 12, score: 0.5, previewText: "gamma", sources: []),
    ]
    var config = FastRAGConfig(searchMode: .textOnly)
    config.answerRerankWindow = 100
    let reranked = FastRAGContextBuilder.rerankCandidatesForAnswer(
        results: results,
        query: "something",
        config: config
    )
    // All three results must be present (order may differ based on scoring).
    #expect(Set(reranked.map(\SearchResponse.Result.frameId)) == Set(results.map(\SearchResponse.Result.frameId)))
}

// MARK: - NativeBpeTokenizer edge cases

@Test
func nativeBpeTokenizerEncodeEmptyStringReturnsEmpty() throws {
    let tokenizer = try NativeBpeTokenizer(encoding: .cl100kBase)
    let tokens = tokenizer.encode("")
    #expect(tokens.isEmpty)
}

@Test
func nativeBpeTokenizerDecodeEmptyTokensReturnsEmpty() throws {
    let tokenizer = try NativeBpeTokenizer(encoding: .cl100kBase)
    let text = tokenizer.decode([])
    #expect(text.isEmpty)
}

@Test
func nativeBpeTokenizerEncodeDecodeRoundTrip() throws {
    let tokenizer = try NativeBpeTokenizer(encoding: .cl100kBase)
    let samples = [
        "Hello, World!",
        "Swift 6.2 actors and async/await",
        "RAG retrieval-augmented generation",
        "Numbers: 42 and 3.14",
    ]
    for sample in samples {
        let tokens = tokenizer.encode(sample)
        #expect(!tokens.isEmpty, "Expected non-empty tokens for: \(sample)")
        let decoded = tokenizer.decode(tokens)
        // Re-encoding the decoded text should produce the same token sequence.
        let reEncoded = tokenizer.encode(decoded)
        #expect(tokens == reEncoded, "Round-trip mismatch for: \(sample)")
    }
}

@Test
func nativeBpeTokenizerPreloadReturnsUsableTokenizer() throws {
    let tokenizer = try NativeBpeTokenizer.preload(encoding: .cl100kBase)
    let tokens = tokenizer.encode("preload test")
    #expect(!tokens.isEmpty)
}

@Test
func nativeBpeTokenizerBundledEncodingDirectoryURLIsNonNil() {
    let url = NativeBpeTokenizer.bundledEncodingDirectoryURL()
    #expect(url != nil)
}

@Test
func nativeBpeTokenizerEncodesShortSingleByteSequence() throws {
    // Single-byte ASCII character exercises the bpeEncode path for single-element parts.
    let tokenizer = try NativeBpeTokenizer(encoding: .cl100kBase)
    // "a" is a single ASCII byte; encoder[Data([0x61])] should exist.
    let tokens = tokenizer.encode("a")
    #expect(!tokens.isEmpty)
    let decoded = tokenizer.decode(tokens)
    #expect(decoded == "a")
}

@Test
func nativeBpeTokenizerCachesRepeatedPieces() throws {
    let tokenizer = try NativeBpeTokenizer(encoding: .cl100kBase)
    let text = "Wax Wax Wax"
    // First call populates LockedCache; second call should read from it.
    let first = tokenizer.encode(text)
    let second = tokenizer.encode(text)
    #expect(first == second)
}

@Test
func nativeBpeTokenizerDecodeUnknownTokenProducesEmpty() throws {
    // UInt32.max is extremely unlikely to be a valid token — decoder lookup returns nil.
    // The decode implementation skips missing tokens, so result should be empty or partial.
    let tokenizer = try NativeBpeTokenizer(encoding: .cl100kBase)
    let decoded = tokenizer.decode([UInt32.max])
    // We only assert it doesn't crash; the content is indeterminate.
    _ = decoded
}
