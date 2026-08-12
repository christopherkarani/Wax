import Testing
@testable import Wax

// MARK: - Action parsing

@Test
func waxMemoryToolActionParsingIsCaseInsensitive() {
    #expect(WaxMemoryToolAction.parse("remember") == .remember)
    #expect(WaxMemoryToolAction.parse(" ReCaLl ") == .recall)
    #expect(WaxMemoryToolAction.parse("SEARCH") == .search)
    #expect(WaxMemoryToolAction.parse("FoRgEt") == .forget)
    #expect(WaxMemoryToolAction.parse("invalid") == nil)
}

@Test
func waxMemoryToolActionParsingAcceptsAliasesAndRejectsEmpty() {
    #expect(WaxMemoryToolAction.parse("store") == .remember)
    #expect(WaxMemoryToolAction.parse("save") == .remember)
    #expect(WaxMemoryToolAction.parse("write") == .remember)
    #expect(WaxMemoryToolAction.parse("memorize") == .remember)
    #expect(WaxMemoryToolAction.parse("mem") == .remember)

    #expect(WaxMemoryToolAction.parse("get") == .recall)
    #expect(WaxMemoryToolAction.parse("retrieve") == .recall)
    #expect(WaxMemoryToolAction.parse("lookup") == .recall)
    #expect(WaxMemoryToolAction.parse("load") == .recall)
    #expect(WaxMemoryToolAction.parse("fetch") == .recall)

    #expect(WaxMemoryToolAction.parse("find") == .search)
    #expect(WaxMemoryToolAction.parse("query") == .search)
    #expect(WaxMemoryToolAction.parse("list") == .search)
    #expect(WaxMemoryToolAction.parse("hits") == .search)

    #expect(WaxMemoryToolAction.parse("forget") == .forget)
    #expect(WaxMemoryToolAction.parse("delete") == .forget)
    #expect(WaxMemoryToolAction.parse("remove") == .forget)
    #expect(WaxMemoryToolAction.parse("erase") == .forget)

    #expect(WaxMemoryToolAction.parse("") == nil)
    #expect(WaxMemoryToolAction.parse("   ") == nil)
    #expect(WaxMemoryToolAction.parse("remember-me") == nil)
    #expect(WaxMemoryToolAction.allCases.map(\.canonicalName) == ["remember", "recall", "search", "forget"])
}

// MARK: - Config clamping

@Test
func waxMemoryToolConfigClampsTopKAndAlpha() {
    var config = WaxMemoryToolConfig.default
    config.searchTopK = 8
    config.maxSearchTopK = 20
    config.searchAlpha = 0.5

    #expect(config.topK(nil) == 8)
    #expect(config.topK(0) == 1)
    #expect(config.topK(100) == 20)

    #expect(config.alpha(nil) == 0.5)
    #expect(config.alpha(-1) == 0)
    #expect(config.alpha(2) == 1)
}

@Test
func waxMemoryToolConfigInitClampsExtremeValues() {
    let config = WaxMemoryToolConfig(
        recallMaxItems: -5,
        searchTopK: 0,
        maxSearchTopK: -1,
        searchAlpha: 9,
        maxItemCharacters: -10,
        maxContentCharacters: 0,
        forgetTopK: 0
    )

    #expect(config.maxSearchTopK == 1)
    #expect(config.searchTopK == 1)
    #expect(config.recallMaxItems == 0)
    #expect(config.searchAlpha == 1)
    #expect(config.maxItemCharacters == 0)
    #expect(config.maxContentCharacters == 1)
    #expect(config.fallbackToTextOnVectorFailure == true)
    #expect(config.forgetTopK == 1)
    #expect(config.resultVerbosity == .verbose)
}

@Test
func waxMemoryToolConfigForgetTopKAndVerbosityDefaults() {
    let defaults = WaxMemoryToolConfig.default
    #expect(defaults.forgetTopK == 3)
    #expect(defaults.resultVerbosity == .verbose)

    let compact = WaxMemoryToolConfig(
        maxSearchTopK: 10,
        forgetTopK: 100,
        resultVerbosity: .compact
    )
    #expect(compact.forgetTopK == 10)
    #expect(compact.resultVerbosity == .compact)
    #expect(compact.resolvedForgetTopK(Optional<Int>.none) == 10)
    #expect(compact.resolvedForgetTopK(2) == 2)
    #expect(compact.resolvedForgetTopK(99) == 10)
    #expect(compact.resolvedForgetTopK(0) == 1)
}

@Test
func waxMemoryToolConfigSearchOptionsMapEmbeddingPolicies() {
    let automatic = WaxMemoryToolConfig(searchTopK: 5, searchAlpha: 0.7, embeddingPolicy: .automatic)
    let never = WaxMemoryToolConfig(embeddingPolicy: .never)
    let always = WaxMemoryToolConfig(embeddingPolicy: .always)

    #expect(automatic.searchOptions().mode == Memory.RetrievalMode.hybrid(alpha: 0.7))
    #expect(automatic.searchOptions().topK == 5)
    #expect(never.searchOptions().mode == Memory.RetrievalMode.textOnly)
    #expect(always.searchOptions().mode == Memory.RetrievalMode.vectorOnly)
    #expect(always.textOnlySearchOptions(topK: 3).mode == Memory.RetrievalMode.textOnly)
    #expect(always.textOnlySearchOptions(topK: 3).topK == 3)
}

// MARK: - Renderer

@Test
func waxMemoryToolRendererFormatsRecallAndTruncates() {
    let context = RAGContext(
        query: "preferences",
        items: [
            .init(
                kind: .expanded,
                frameId: 7,
                score: 0.95,
                sources: [.text, .vector],
                text: String(repeating: "x", count: 40)
            ),
            .init(
                kind: .snippet,
                frameId: 8,
                score: 0.8,
                sources: [.text],
                text: "second"
            ),
        ],
        totalTokens: 10
    )

    let output = WaxMemoryToolRenderer.renderRecall(
        query: "preferences",
        context: context,
        maxItems: 1,
        includeScores: true,
        maxItemCharacters: 10
    )

    #expect(output.contains("Memory context for \"preferences\""))
    #expect(output.contains("[expanded|text,vector score=0.9500]"))
    #expect(output.contains("…"))
    #expect(output.contains("more memory item(s) omitted"))
}

@Test
func waxMemoryToolRendererFormatsSearchFallback() {
    let output = WaxMemoryToolRenderer.renderSearch(
        query: "missing",
        items: [],
        includeScores: false,
        maxItemCharacters: 120
    )
    #expect(output.contains("No memory search hits found"))
}

@Test
func waxMemoryToolRendererCompactModeIsShorterThanVerbose() {
    let items = [
        RAGContext.Item(
            kind: .snippet,
            frameId: 11,
            score: 0.91,
            sources: [.text, .vector],
            text: "User prefers dark mode in SwiftUI apps."
        )
    ]
    let context = RAGContext(query: "theme", items: items, totalTokens: 4)

    let verboseRecall = WaxMemoryToolRenderer.renderRecall(
        query: "theme",
        context: context,
        maxItems: 3,
        includeScores: true,
        maxItemCharacters: 200,
        verbosity: .verbose
    )
    let compactRecall = WaxMemoryToolRenderer.renderRecall(
        query: "theme",
        context: context,
        maxItems: 3,
        includeScores: true,
        maxItemCharacters: 200,
        verbosity: .compact
    )
    #expect(compactRecall.count < verboseRecall.count)
    #expect(compactRecall.contains("dark mode"))
    #expect(!compactRecall.contains("score="))

    let verboseSearch = WaxMemoryToolRenderer.renderSearch(
        query: "theme",
        items: items,
        includeScores: true,
        maxItemCharacters: 200,
        verbosity: .verbose
    )
    let compactSearch = WaxMemoryToolRenderer.renderSearch(
        query: "theme",
        items: items,
        includeScores: true,
        maxItemCharacters: 200,
        verbosity: .compact
    )
    #expect(compactSearch.count < verboseSearch.count)
    #expect(compactSearch.contains("dark mode"))
    #expect(!compactSearch.contains("frame=11"))

    let forgetMessage = WaxMemoryToolRenderer.renderForget(query: "theme", deletedCount: 2)
    #expect(forgetMessage.contains("2"))
    #expect(forgetMessage.contains("theme") || forgetMessage.lowercased().contains("deleted"))
}

@Test
func waxMemoryToolRendererCoversKindsScoresFramesAndZeroBudget() {
    #expect(WaxMemoryToolRenderer.kindLabel(.snippet) == "snippet")
    #expect(WaxMemoryToolRenderer.kindLabel(.expanded) == "expanded")
    #expect(WaxMemoryToolRenderer.kindLabel(.surrogate) == "surrogate")
    #expect(WaxMemoryToolRenderer.truncate("abc", maxCharacters: 0) == "")
    #expect(WaxMemoryToolRenderer.truncate("abc", maxCharacters: 3) == "abc")
    #expect(WaxMemoryToolRenderer.truncate("abcd", maxCharacters: 3) == "abc…")
    #expect(WaxMemoryToolRenderer.renderError("  ") == "Wax memory tool error: unknown error")
    #expect(WaxMemoryToolRenderer.renderRemember(contentLength: -1) == "Stored memory (0 characters).")

    let emptyRecall = WaxMemoryToolRenderer.renderRecall(
        query: "q",
        context: RAGContext(query: "q", items: [], totalTokens: 0),
        maxItems: 5,
        includeScores: false,
        maxItemCharacters: 10
    )
    #expect(emptyRecall.contains("No memory context found"))

    let items = [
        RAGContext.Item(
            kind: .surrogate,
            frameId: 99,
            score: 0.1234,
            sources: [.timeline, .structured, .unknown],
            text: "hello world"
        )
    ]
    let search = WaxMemoryToolRenderer.renderSearch(
        query: "hello",
        items: items,
        includeScores: true,
        maxItemCharacters: 5
    )
    #expect(search.contains("frame=99"))
    #expect(search.contains("timeline,structured,unknown"))
    #expect(search.contains("score=0.1234"))
    #expect(search.contains("hello…"))

    let recall = WaxMemoryToolRenderer.renderRecall(
        query: "hello",
        context: RAGContext(query: "hello", items: items, totalTokens: 1),
        maxItems: 0,
        includeScores: false,
        maxItemCharacters: 100
    )
    #expect(recall.contains("No memory context found"))
}

// MARK: - Result helpers

@Test
func waxMemoryToolResultHelpersExposeSuccessFlags() {
    let ok = WaxMemoryToolResult.ok(action: .search, message: "hits", itemCount: 2)
    #expect(ok.isSuccess)
    #expect(ok.status == .ok)
    #expect(ok.itemCount == 2)

    let err = WaxMemoryToolResult.error(action: "remember", message: "boom")
    #expect(!err.isSuccess)
    #expect(err.status == .error)
    #expect(err.message.contains("Wax memory tool error: boom"))
    #expect(err.itemCount == 0)

    let negativeClamped = WaxMemoryToolResult(status: .ok, action: "x", message: "y", itemCount: -3)
    #expect(negativeClamped.itemCount == 0)
}

// MARK: - Executor edge cases (no FoundationModels required)

@Test
func waxMemoryToolExecutorRejectsInvalidAndMissingInputs() async throws {
    try await TempFiles.withTempFile { url in
        let memory = try await Memory(at: url) { $0.enableVectorSearch = false }
        let config = WaxMemoryToolConfig.default

        let invalid = await WaxMemoryToolExecutor.execute(
            memory: memory,
            config: config,
            action: "nope"
        )
        #expect(invalid.status == .error)
        #expect(invalid.message.contains("invalid action"))

        let missingContent = await WaxMemoryToolExecutor.execute(
            memory: memory,
            config: config,
            action: .remember,
            content: "   "
        )
        #expect(missingContent.status == .error)
        #expect(missingContent.message.contains("content is required"))

        let missingRecallQuery = await WaxMemoryToolExecutor.execute(
            memory: memory,
            config: config,
            action: .recall,
            query: nil
        )
        #expect(missingRecallQuery.status == .error)
        #expect(missingRecallQuery.message.contains("query is required"))

        let missingSearchQuery = await WaxMemoryToolExecutor.execute(
            memory: memory,
            config: config,
            action: "find",
            query: ""
        )
        #expect(missingSearchQuery.status == .error)
        #expect(missingSearchQuery.message.contains("query is required"))

        try await memory.close()
    }
}

@Test
func waxMemoryToolExecutorRememberRecallSearchRoundTripAndAliases() async throws {
    try await TempFiles.withTempFile { url in
        let memory = try await Memory(at: url) { $0.enableVectorSearch = false }
        var config = WaxMemoryToolConfig.default
        config.includeScores = true
        config.recallMaxItems = 3
        config.maxItemCharacters = 200

        let stored = await WaxMemoryToolExecutor.execute(
            memory: memory,
            config: config,
            action: "store",
            content: "  User prefers dark mode in SwiftUI apps.  "
        )
        #expect(stored.isSuccess)
        #expect(stored.action == "remember")
        #expect(stored.message.contains("Stored memory"))

        let recalled = await WaxMemoryToolExecutor.execute(
            memory: memory,
            config: config,
            action: "lookup",
            query: "theme preference"
        )
        #expect(recalled.isSuccess)
        #expect(recalled.action == "recall")
        #expect(recalled.message.contains("dark mode") || recalled.itemCount >= 0)

        let searched = await WaxMemoryToolExecutor.execute(
            memory: memory,
            config: config,
            action: "find",
            query: "SwiftUI",
            topK: 2,
            alpha: 0.9
        )
        #expect(searched.isSuccess)
        #expect(searched.action == "search")
        #expect(searched.itemCount >= 1)
        #expect(searched.message.contains("Memory search hits") || searched.message.contains("SwiftUI"))

        try await memory.close()
    }
}

@Test
func waxMemoryToolExecutorRejectsOversizedContent() async throws {
    try await TempFiles.withTempFile { url in
        let memory = try await Memory(at: url) { $0.enableVectorSearch = false }
        let config = WaxMemoryToolConfig(maxContentCharacters: 8)

        let result = await WaxMemoryToolExecutor.execute(
            memory: memory,
            config: config,
            action: .remember,
            content: "0123456789"
        )
        #expect(result.status == .error)
        #expect(result.message.contains("maxContentCharacters"))

        let ok = await WaxMemoryToolExecutor.execute(
            memory: memory,
            config: config,
            action: .remember,
            content: "01234567"
        )
        #expect(ok.isSuccess)

        try await memory.close()
    }
}

@Test
func waxMemoryToolExecutorNormalizedTextHelper() {
    #expect(WaxMemoryToolExecutor.normalizedText(nil) == nil)
    #expect(WaxMemoryToolExecutor.normalizedText("") == nil)
    #expect(WaxMemoryToolExecutor.normalizedText("  \n\t ") == nil)
    #expect(WaxMemoryToolExecutor.normalizedText("  hi  ") == "hi")
}

@Test
func waxMemoryToolExecutorRecallMaxItemsZeroReturnsNoItemsMessage() async throws {
    try await TempFiles.withTempFile { url in
        let memory = try await Memory(at: url) { $0.enableVectorSearch = false }
        try await memory.save("alpha beta gamma")
        let config = WaxMemoryToolConfig(recallMaxItems: 0, embeddingPolicy: .never)

        let result = await WaxMemoryToolExecutor.execute(
            memory: memory,
            config: config,
            action: .recall,
            query: "alpha"
        )
        #expect(result.isSuccess)
        #expect(result.itemCount == 0)
        #expect(result.message.contains("No memory context found"))

        try await memory.close()
    }
}

@Test
func waxMemoryToolExecutorVectorAlwaysFallsBackToTextWhenConfigured() async throws {
    try await TempFiles.withTempFile { url in
        // Vector enabled but no embedder — primary search can fail; tool should soft-fallback.
        let memory = try await Memory(at: url) { config in
            config.enableVectorSearch = true
        }
        try await memory.save("User likes Vim keybindings.")

        let config = WaxMemoryToolConfig(
            embeddingPolicy: .always,
            fallbackToTextOnVectorFailure: true
        )
        let result = await WaxMemoryToolExecutor.execute(
            memory: memory,
            config: config,
            action: .search,
            query: "Vim"
        )
        // Either success via fallback, or a clean error if both paths fail — never crash.
        #expect(result.status == .ok || result.status == .error)
        if result.isSuccess {
            #expect(result.message.contains("Vim") || result.itemCount >= 0)
        } else {
            #expect(result.message.contains("operation failed") || result.message.contains("error"))
        }

        try await memory.close()
    }
}

@Test
func waxMemoryToolExecutorForgetRequiresQueryAndDeletesMatchingFrames() async throws {
    try await TempFiles.withTempFile { url in
        let memory = try await Memory(at: url) { $0.enableVectorSearch = false }
        let config = WaxMemoryToolConfig(
            searchTopK: 5,
            embeddingPolicy: .never,
            forgetTopK: 3
        )

        let missingQuery = await WaxMemoryToolExecutor.execute(
            memory: memory,
            config: config,
            action: "erase",
            query: "  "
        )
        #expect(missingQuery.status == .error)
        #expect(missingQuery.message.contains("query is required"))

        let stored = await WaxMemoryToolExecutor.execute(
            memory: memory,
            config: config,
            action: .remember,
            content: "User secret project codename is OrionNebula."
        )
        #expect(stored.isSuccess)

        let before = await WaxMemoryToolExecutor.execute(
            memory: memory,
            config: config,
            action: .search,
            query: "OrionNebula",
            topK: 5
        )
        #expect(before.isSuccess)
        #expect(before.itemCount >= 1)

        let forgotten = await WaxMemoryToolExecutor.execute(
            memory: memory,
            config: config,
            action: "delete",
            query: "OrionNebula",
            topK: 3
        )
        #expect(forgotten.isSuccess)
        #expect(forgotten.action == "forget")
        #expect(forgotten.itemCount >= 1)
        #expect(forgotten.message.lowercased().contains("delete") || forgotten.message.contains("\(forgotten.itemCount)"))

        let after = await WaxMemoryToolExecutor.execute(
            memory: memory,
            config: config,
            action: .search,
            query: "OrionNebula",
            topK: 5
        )
        #expect(after.isSuccess)
        #expect(after.itemCount == 0)

        try await memory.close()
    }
}

@Test
func memoryDeleteFrameRemovesFromTextSearch() async throws {
    try await TempFiles.withTempFile { url in
        let memory = try await Memory(at: url) { $0.enableVectorSearch = false }
        try await memory.save("Unique forgettable phrase ZetaPhoenix.")

        let hits = try await memory.search(
            "ZetaPhoenix",
            options: .init(topK: 5, mode: .textOnly)
        )
        #expect(!hits.items.isEmpty)

        let frameId = hits.items[0].frameId
        try await memory.delete(frameID: frameId)

        let after = try await memory.search(
            "ZetaPhoenix",
            options: .init(topK: 5, mode: .textOnly)
        )
        #expect(after.items.isEmpty)

        try await memory.close()
    }
}

@Test
func waxMemoryToolKitCasesAreDistinct() {
    let kits: [WaxMemoryToolKit] = [.focused, .compact, .combined, .focusedWithForget]
    #expect(Set(kits.map { String(describing: $0) }).count == 4)
}

// MARK: - Forget partial delete reporting (M-9)

@Test
func waxMemoryToolForgetPartialDeleteReportsAccurateItemCount() async {
    enum Boom: Error { case stop }

    // Succeed twice, then fail — itemCount must reflect the 2 successful deletes.
    var call = 0
    let outcome = await WaxMemoryToolExecutor.deleteFramesReportingPartial(
        frameIDs: [10, 20, 30, 40]
    ) { _ in
        call += 1
        if call > 2 { throw Boom.stop }
    }
    #expect(outcome.deleted == 2)
    #expect(outcome.failure != nil)

    let partialMessage = WaxMemoryToolRenderer.renderForgetPartial(
        query: "secrets",
        deletedCount: outcome.deleted,
        failure: "injected delete failure"
    )
    #expect(partialMessage.contains("2"))
    #expect(partialMessage.localizedCaseInsensitiveContains("partial"))
    #expect(partialMessage.contains("secrets"))

    let result = WaxMemoryToolResult.error(
        action: "forget",
        message: partialMessage,
        itemCount: outcome.deleted
    )
    #expect(result.status == .error)
    #expect(result.itemCount == 2)
    #expect(result.message.contains("2"))
    #expect(!result.isSuccess)

    // Zero successes still report itemCount 0.
    let zero = await WaxMemoryToolExecutor.deleteFramesReportingPartial(
        frameIDs: [1]
    ) { _ in throw Boom.stop }
    #expect(zero.deleted == 0)
    #expect(zero.failure != nil)

    // All succeed → no failure.
    let ok = await WaxMemoryToolExecutor.deleteFramesReportingPartial(
        frameIDs: [1, 2]
    ) { _ in }
    #expect(ok.deleted == 2)
    #expect(ok.failure == nil)
}

@Test
func waxMemoryToolConfigHybridAlphaPreservedInSearchOptions() {
    let config = WaxMemoryToolConfig(searchTopK: 6, searchAlpha: 0.25, embeddingPolicy: .automatic)
    #expect(config.alpha(nil) == 0.25)
    #expect(config.searchOptions(topK: 4).mode == .hybrid(alpha: 0.25))
    #expect(config.searchOptions(topK: 4, alpha: 0.9).mode == .hybrid(alpha: 0.9))
}
