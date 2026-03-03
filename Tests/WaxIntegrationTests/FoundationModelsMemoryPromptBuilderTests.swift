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
func foundationModelsSessionConfigDefaultsAreProductionFriendly() {
    let config = FoundationModelsMemorySessionConfig.default

    #expect(config.persistencePolicy == .userAndAssistant)
    #expect(config.queryEmbeddingPolicy == .ifAvailable)
    #expect(config.userMetadata["wax.channel"] == "foundation_models")
    #expect(config.userMetadata["wax.role"] == "user")
    #expect(config.assistantMetadata["wax.role"] == "assistant")
}
