import Foundation

#if canImport(WaxVectorSearchMiniLM)
import WaxVectorSearchMiniLM
#endif

public enum WaxPrewarm {
    public static func tokenizer() async {
        _ = try? await TokenCounter.shared()
    }

    #if canImport(WaxVectorSearchMiniLM)
    public static func miniLM(sampleText: String = "hello") async throws {
        let embedder = try MiniLMEmbedder()
        try await embedder.prewarm()
    }
    #endif
}
