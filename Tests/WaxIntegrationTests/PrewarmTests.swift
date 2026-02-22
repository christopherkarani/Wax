import Testing
import Wax

@Test
func waxPrewarmTokenizerWarmsSharedCounterWithoutThrowing() async throws {
    await WaxPrewarm.tokenizer()
    let counter = try await TokenCounter.shared()
    let tokens = await counter.encode("wax tokenizer prewarm")
    #expect(!tokens.isEmpty)
}
