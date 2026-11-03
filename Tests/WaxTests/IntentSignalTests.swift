import Testing
@testable import Wax

/// Intent and answer-shape signals must match whole words, not substrings,
/// and must not key on benchmark-fixture vocabulary.
@Suite("Intent signals")
struct IntentSignalTests {
    private let analyzer = QueryAnalyzer()

    @Test(arguments: [
        "How do I update the billing profile?",
        "Validate the import before running it",
        "Notes from the Orion launch review",
        "Show the Orion project timeline",
    ])
    func detectIntentIgnoresDateSubstringsAndFixtureTriggers(query: String) {
        #expect(!analyzer.detectIntent(query: query).contains(.asksDate))
    }

    @Test
    func detectIntentIgnoresLocationAndOwnershipSubstrings() {
        #expect(!analyzer.detectIntent(query: "What is the capacity of the cold room?").contains(.asksLocation))
        #expect(!analyzer.detectIntent(query: "Summarize the whole quarter").contains(.asksOwnership))
    }

    @Test
    func detectIntentStillFlagsWholeWordCues() {
        #expect(analyzer.detectIntent(query: "When is Avery's dentist appointment?").contains(.asksDate))
        #expect(analyzer.detectIntent(query: "What is the release date for Nova?").contains(.asksDate))
        #expect(analyzer.detectIntent(query: "Which city did Avery move to?").contains(.asksLocation))
        #expect(analyzer.detectIntent(query: "Where is Avery flying?").contains(.asksLocation))
        #expect(analyzer.detectIntent(query: "Who owns the Nova rollout?").contains(.asksOwnership))
        #expect(analyzer.detectIntent(query: "Whose laptop is this?").contains(.asksOwnership))
    }

    @Test(arguments: [
        "the spec was drafted on may 3, 2026",
        "overdraft fees apply from june 1, 2026",
        "the estimated cost was settled on june 1, 2026",
    ])
    func tentativeLanguageMatchesWholeWordsOnly(text: String) {
        #expect(!RerankingHelpers.containsTentativeLanguage(text))
    }

    @Test
    func tentativeLanguageStillMatchesHedges() {
        #expect(RerankingHelpers.containsTentativeLanguage("this is a draft schedule"))
        #expect(RerankingHelpers.containsTentativeLanguage("current estimate is june"))
        #expect(RerankingHelpers.containsTentativeLanguage("pending approval from finance"))
    }

    @Test
    func relocationIgnoresCalendarMoves() {
        #expect(!RerankingHelpers.containsRelocationStatement("The standup moved to Friday."))
        #expect(!RerankingHelpers.containsRelocationStatement("Launch moved to March 3."))
        #expect(!RerankingHelpers.containsMoveToPhrase("the standup moved to friday."))
        #expect(!RerankingHelpers.containsMoveToPhrase("the files were removed to save space."))
        #expect(RerankingHelpers.containsRelocationStatement("Avery moved to Seattle in 2021."))
        #expect(RerankingHelpers.containsMoveToPhrase("avery moved to seattle in 2021."))
    }

    @Test
    func dateQueryDoesNotPenalizeDraftedOrEstimatedWords() {
        let drafted = result(1, 0.60, "Orion contract was drafted and signed on May 3, 2026.")
        let plain = result(2, 0.50, "Orion contract notes: signing happened on May 4, 2026.")
        let ranked = UnifiedRanking.intentAwareRerank(
            results: [drafted, plain],
            query: "When was the Orion contract signed?",
            maxWindow: 10
        )
        #expect(ranked.map(\.frameId) == [1, 2])
    }

    @Test
    func locationQueryDoesNotTreatCalendarMoveAsRelocation() {
        let calendar = result(1, 0.60, "Avery's weekly sync moved to Friday.")
        let relocation = result(2, 0.50, "Avery moved to Seattle last spring.")
        let ranked = UnifiedRanking.intentAwareRerank(
            results: [calendar, relocation],
            query: "Where does Avery live now that Avery moved?",
            maxWindow: 10
        )
        #expect(ranked.first?.frameId == 2)
    }

    // MARK: - Snippet expansion for date intent

    @Test
    func dateSnippetKeepsPreviewWhenFrameHasNoDate() {
        let preview = "Orion review notes cover staffing."
        let frame = preview + " The team discussed hiring and budget, with no schedule yet."
        let text = FastRAGContextBuilder.expandedSnippetText(
            preview: preview,
            frameText: frame,
            intent: [.asksDate],
            analyzer: analyzer,
            maxCharacters: 600
        )
        #expect(text == preview)
    }

    @Test
    func dateSnippetCentersLongFrameOnTheDate() {
        let filler = String(repeating: "Background notes about staffing and budget. ", count: 40)
        let frame = filler + "The Orion review is on March 3, 2026. " + filler
        let preview = "Orion review notes cover staffing"
        let text = FastRAGContextBuilder.expandedSnippetText(
            preview: preview,
            frameText: frame,
            intent: [.asksDate],
            analyzer: analyzer,
            maxCharacters: 400
        )
        #expect(text.contains("March 3, 2026"))
        #expect(text.count <= 400)
    }

    /// CJK text costs about a token per character, so a window sized in
    /// characters must still keep the date inside the token budget that
    /// recall assembly truncates to (from the start).
    @Test
    func dateSnippetWindowKeepsDateInsideTokenBudgetForCJK() async throws {
        let filler = String(repeating: "日本語の調査メモと予算の背景説明。", count: 60)
        let frame = filler + "審査日は 2026-03-03 です。" + filler
        let maxTokens = 100
        let counter = try await TokenCounter.shared()
        let text = await FastRAGContextBuilder.tokenFittedSnippetText(
            preview: "日本語の調査メモ",
            frameText: frame,
            intent: [.asksDate],
            analyzer: analyzer,
            maxTokens: maxTokens,
            countTokens: { await counter.count($0) }
        )
        let truncated = await counter.truncate(text, maxTokens: maxTokens)
        #expect(truncated.contains("2026-03-03"))
    }

    private func result(_ frameId: UInt64, _ score: Float, _ preview: String) -> SearchResponse.Result {
        SearchResponse.Result(frameId: frameId, score: score, previewText: preview, sources: [.text])
    }
}
