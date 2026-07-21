import Testing
import Wax

@Test
func foundationModelsPromptBuilderReturnsUserPromptWhenNoMemoryItems() {
    let builder = FoundationModelsMemoryPromptBuilder()
    let context = RAGContext(query: "swift", items: [], totalTokens: 0)

    let prompt = builder.build(userPrompt: "Explain actors", context: context)

    #expect(prompt == "Explain actors")
}

@Test
func foundationModelsPromptBuilderIncludesMemoryBlockAndRespectsItemLimit() {
    let builder = FoundationModelsMemoryPromptBuilder(maxItems: 1, includeScores: true)
    let context = RAGContext(
        query: "swift",
        items: [
            .init(
                kind: .expanded,
                frameId: 42,
                score: 0.91,
                sources: [.text, .vector],
                text: "User prefers concise Swift answers."
            ),
            .init(
                kind: .snippet,
                frameId: 43,
                score: 0.52,
                sources: [.text],
                text: "This second item should be truncated."
            ),
        ],
        totalTokens: 28
    )

    let prompt = builder.build(userPrompt: "How should I answer?", context: context)

    #expect(prompt.contains("<wax_memory>"))
    #expect(prompt.contains("[expanded|text,vector"))
    #expect(prompt.contains("User prefers concise Swift answers."))
    #expect(prompt.contains("score=0.9100"))
    #expect(!prompt.contains("This second item should be truncated."))
    #expect(prompt.contains("<user_prompt>"))
    #expect(prompt.contains("How should I answer?"))
}

@Test
func foundationModelsPromptBuilderPlainBulletsOmitsXMLTags() {
    let builder = FoundationModelsMemoryPromptBuilder(
        maxItems: 2,
        injectionStyle: .plainBullets
    )
    let context = RAGContext(
        query: "prefs",
        items: [
            .init(
                kind: .snippet,
                frameId: 1,
                score: 0.8,
                sources: [.text],
                text: "Likes short answers."
            ),
        ],
        totalTokens: 4
    )

    let prompt = builder.build(userPrompt: "Hello", context: context)

    #expect(!prompt.contains("<wax_memory>"))
    #expect(!prompt.contains("</wax_memory>"))
    #expect(!prompt.contains("<user_prompt>"))
    #expect(!prompt.contains("</user_prompt>"))
    #expect(prompt.contains("Likes short answers."))
    #expect(prompt.contains("Hello"))
    #expect(prompt.contains("- ") || prompt.contains("• "))
}

@Test
func foundationModelsPromptBuilderInstructionsAppendixOmitsXMLAndKeepsUserPrompt() {
    let builder = FoundationModelsMemoryPromptBuilder(
        maxItems: 2,
        injectionStyle: .instructionsAppendix
    )
    let context = RAGContext(
        query: "prefs",
        items: [
            .init(
                kind: .expanded,
                frameId: 7,
                score: 0.9,
                sources: [.vector],
                text: "User lives in Nairobi."
            ),
        ],
        totalTokens: 5
    )

    let prepared = builder.prepare(userPrompt: "Where am I?", context: context)

    // instructionsAppendix: bare user prompt; memory lives in memoryAppendix.
    #expect(prepared.prompt == "Where am I?")
    #expect(!prepared.prompt.contains("<wax_memory>"))
    #expect(!prepared.prompt.contains("<user_prompt>"))
    #expect(!prepared.prompt.contains("User lives in Nairobi."))
    #expect(prepared.memoryAppendix != nil)
    #expect(prepared.memoryAppendix?.contains("User lives in Nairobi.") == true)
    #expect(prepared.memoryAppendix?.contains("Recalled memory context") == true)
    #expect(prepared.memoryAppendix?.contains("Memory query: prefs") == true)
    #expect(!prepared.memoryAppendix!.contains("Where am I?"))
    #expect(prepared.includedItemCount == 1)
    #expect(prepared.recalledItemCount == 1)
    #expect(prepared.truncatedByBudget == false)

    // build() returns only the bare user prompt for this style.
    let built = builder.build(userPrompt: "Where am I?", context: context)
    #expect(built == "Where am I?")

    // No memory → user prompt alone, nil appendix.
    let emptyPrepared = builder.prepare(
        userPrompt: "Only me",
        context: RAGContext(query: "x", items: [], totalTokens: 0)
    )
    #expect(emptyPrepared.prompt == "Only me")
    #expect(emptyPrepared.memoryAppendix == nil)
    let empty = builder.build(
        userPrompt: "Only me",
        context: RAGContext(query: "x", items: [], totalTokens: 0)
    )
    #expect(empty == "Only me")
}

@Test
func foundationModelsPromptBuilderOtherStylesLeaveMemoryAppendixNil() {
    let memoryText = "Unique-memory-marker-xml-style"
    let context = RAGContext(
        query: "q",
        items: [
            .init(kind: .snippet, frameId: 1, score: 1, sources: [.text], text: memoryText),
        ],
        totalTokens: 1
    )

    let xml = FoundationModelsMemoryPromptBuilder(injectionStyle: .xmlTags)
        .prepare(userPrompt: "Ask", context: context)
    #expect(xml.memoryAppendix == nil)
    #expect(xml.prompt.contains(memoryText))
    #expect(xml.prompt.contains("Ask"))

    let bullets = FoundationModelsMemoryPromptBuilder(injectionStyle: .plainBullets)
        .prepare(userPrompt: "Ask", context: context)
    #expect(bullets.memoryAppendix == nil)
    #expect(bullets.prompt.contains(memoryText))
}

@Test
func foundationModelsPromptBuilderCharacterBudgetStopsAndTruncatesItems() {
    let longA = String(repeating: "A", count: 40)
    let longB = String(repeating: "B", count: 40)
    let longC = String(repeating: "C", count: 40)
    let builder = FoundationModelsMemoryPromptBuilder(
        maxItems: 10,
        maxMemoryCharacters: 50,
        injectionStyle: .xmlTags
    )
    let context = RAGContext(
        query: "budget",
        items: [
            .init(kind: .snippet, frameId: 1, score: 1, sources: [.text], text: longA),
            .init(kind: .snippet, frameId: 2, score: 0.9, sources: [.text], text: longB),
            .init(kind: .snippet, frameId: 3, score: 0.8, sources: [.text], text: longC),
        ],
        totalTokens: 30
    )

    let prepared = builder.prepare(userPrompt: "Q", context: context)

    // First item (40 chars) fits; second (40) exceeds remaining 10 → truncated include.
    #expect(prepared.includedItemCount == 2)
    #expect(prepared.recalledItemCount == 3)
    #expect(prepared.truncatedByBudget == true)
    #expect(prepared.prompt.contains(longA))
    #expect(!prepared.prompt.contains(longB)) // full B should not appear
    #expect(prepared.prompt.contains("B")) // truncated prefix of B
    #expect(!prepared.prompt.contains("C")) // third item dropped
    #expect(prepared.prompt.contains("…") || prepared.prompt.contains("..."))
}

@Test
func foundationModelsPromptBuilderSingleItemExceedingBudgetIsTruncated() {
    let huge = String(repeating: "Z", count: 200)
    let builder = FoundationModelsMemoryPromptBuilder(
        maxItems: 5,
        maxMemoryCharacters: 20
    )
    let context = RAGContext(
        query: "one",
        items: [
            .init(kind: .snippet, frameId: 1, score: 1, sources: [.text], text: huge),
        ],
        totalTokens: 50
    )

    let prepared = builder.prepare(userPrompt: "Q", context: context)

    #expect(prepared.includedItemCount == 1)
    #expect(prepared.truncatedByBudget == true)
    #expect(!prepared.prompt.contains(huge))
    #expect(prepared.prompt.contains(String(repeating: "Z", count: 20)))
}

@Test
func foundationModelsPromptBuilderNilBudgetUsesMaxItemsOnly() {
    let builder = FoundationModelsMemoryPromptBuilder(
        maxItems: 2,
        maxMemoryCharacters: nil
    )
    let items: [RAGContext.Item] = (1...4).map { i in
        .init(
            kind: .snippet,
            frameId: UInt64(i),
            score: 1,
            sources: [.text],
            text: String(repeating: "X", count: 500)
        )
    }
    let context = RAGContext(query: "q", items: items, totalTokens: 100)
    let prepared = builder.prepare(userPrompt: "P", context: context)

    #expect(prepared.includedItemCount == 2)
    #expect(prepared.recalledItemCount == 4)
    #expect(prepared.truncatedByBudget == false)
}

@Test
func foundationModelsPromptBuilderPrepareMatchesBuildPrompt() {
    let builder = FoundationModelsMemoryPromptBuilder(maxItems: 1, includeScores: false)
    let context = RAGContext(
        query: "q",
        items: [
            .init(kind: .snippet, frameId: 1, score: 0.5, sources: [.text], text: "fact"),
        ],
        totalTokens: 1
    )
    let prepared = builder.prepare(userPrompt: "Ask", context: context)
    let built = builder.build(userPrompt: "Ask", context: context)
    #expect(prepared.prompt == built)
}

@Test
func foundationModelsSessionConfigDefaultsAreProductionFriendly() {
    let config = FoundationModelsMemorySessionConfig.default

    #expect(config.persistencePolicy == .userAndAssistant)
    #expect(config.contextStrategy == .hybrid)
    #expect(config.embeddingPolicy == .automatic)
    #expect(config.includeMemoryTools == true)
    #expect(config.shouldAugmentPrompt == true)
    #expect(config.userMetadata["wax.channel"] == "foundation_models")
    #expect(config.userMetadata["wax.role"] == "user")
    #expect(config.assistantMetadata["wax.role"] == "assistant")
    #expect(config.injectionStyle == .xmlTags)
    #expect(config.memoryCharacterBudget == 1_200)
    #expect(config.structuredPersistence == .stringDescribing)
    #expect(config.toolKit == .focused)
    #expect(config.promptBuilder.maxItems == 4)
    #expect(config.promptBuilder.maxMemoryCharacters == 1_200)
    #expect(config.promptBuilder.injectionStyle == .xmlTags)
}

@Test
func foundationModelsSessionConfigDurableFactsOnlySkipsChatTurnPersistence() {
    let policy = FoundationModelsMemorySessionConfig.PersistencePolicy.durableFactsOnly
    #expect(policy.shouldPersistUser == false)
    #expect(policy.shouldPersistAssistant == false)
}

@Test
func foundationModelsSessionConfigPresetsMatchDocumentedStrategies() {
    let toolsOnly = FoundationModelsMemorySessionConfig.toolsOnlyCompact
    #expect(toolsOnly.contextStrategy == .tools)
    #expect(toolsOnly.includeMemoryTools == true)
    #expect(toolsOnly.shouldAugmentPrompt == false)
    #expect(toolsOnly.toolKit == .compact)

    let promptOnly = FoundationModelsMemorySessionConfig.promptOnlyLight
    #expect(promptOnly.contextStrategy == .promptAugmentation)
    #expect(promptOnly.includeMemoryTools == false)
    #expect(promptOnly.shouldAugmentPrompt == true)
    #expect(promptOnly.promptBuilder.maxItems == 3)
    #expect(promptOnly.memoryCharacterBudget == 800)
    #expect(promptOnly.promptBuilder.maxMemoryCharacters == 800)

    let hybrid = FoundationModelsMemorySessionConfig.hybridBalanced
    #expect(hybrid.contextStrategy == .hybrid)
    #expect(hybrid.includeMemoryTools == true)
    #expect(hybrid.shouldAugmentPrompt == true)
    #expect(hybrid.promptBuilder.maxItems == 4)
    #expect(hybrid.memoryCharacterBudget == 1_200)
    #expect(hybrid.promptBuilder.maxMemoryCharacters == 1_200)

    // Default stays close to hybridBalanced (production-friendly tighter hybrid).
    let defaults = FoundationModelsMemorySessionConfig.default
    #expect(defaults.contextStrategy == hybrid.contextStrategy)
    #expect(defaults.promptBuilder.maxItems == hybrid.promptBuilder.maxItems)
    #expect(defaults.memoryCharacterBudget == hybrid.memoryCharacterBudget)
}

@Test
func foundationModelsToolConfigBuildsSearchOptionsFromEmbeddingPolicy() {
    let automatic = WaxMemoryToolConfig(searchTopK: 5, searchAlpha: 0.7, embeddingPolicy: .automatic)
    let never = WaxMemoryToolConfig(embeddingPolicy: .never)
    let always = WaxMemoryToolConfig(embeddingPolicy: .always)

    let automaticOptions = automatic.searchOptions()
    let neverOptions = never.searchOptions()
    let alwaysOptions = always.searchOptions()

    #expect(automaticOptions.topK == 5)
    #expect(automaticOptions.mode == Memory.RetrievalMode.hybrid(alpha: 0.7))
    #expect(neverOptions.mode == Memory.RetrievalMode.textOnly)
    #expect(alwaysOptions.mode == Memory.RetrievalMode.vectorOnly)
    #expect(always.fallbackToTextOnVectorFailure == true)
    #expect(always.maxContentCharacters == 8_000)
}
