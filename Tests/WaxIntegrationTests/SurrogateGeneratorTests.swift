import Testing
import Wax

private actor SurrogateCallRecorder {
    private(set) var calls: [(sourceText: String, maxTokens: Int)] = []

    func record(sourceText: String, maxTokens: Int) {
        calls.append((sourceText, maxTokens))
    }

    func snapshot() -> [(sourceText: String, maxTokens: Int)] {
        calls
    }
}

private struct TestHierarchicalGenerator: HierarchicalSurrogateGenerator {
    let algorithmID = "test_hierarchical_v1"
    let recorder: SurrogateCallRecorder

    func generateSurrogate(sourceText: String, maxTokens: Int) async throws -> String {
        await recorder.record(sourceText: sourceText, maxTokens: maxTokens)
        return "\(sourceText)-\(maxTokens)"
    }
}

@Test
func hierarchicalGeneratorDefaultGenerateTiersUsesConfiguredBudgets() async throws {
    let recorder = SurrogateCallRecorder()
    let generator = TestHierarchicalGenerator(recorder: recorder)
    let config = SurrogateTierConfig(fullMaxTokens: 120, gistMaxTokens: 30, microMaxTokens: 9)

    let tiers = try await generator.generateTiers(sourceText: "alpha", config: config)

    #expect(tiers.full == "alpha-120")
    #expect(tiers.gist == "alpha-30")
    #expect(tiers.micro == "alpha-9")

    let calls = await recorder.snapshot()
    #expect(calls.count == 3)
    #expect(calls[0].maxTokens == 120)
    #expect(calls[1].maxTokens == 30)
    #expect(calls[2].maxTokens == 9)
}
