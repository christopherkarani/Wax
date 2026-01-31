import Foundation

#if canImport(WaxVectorSearchMiniLM)
import WaxVectorSearchMiniLM
#endif

public enum WaxPrewarm {
    public static func tokenizer() async {
        _ = try? await TokenCounter.shared()
    }

    #if canImport(WaxVectorSearchMiniLM)
    public static func miniLM(sampleText: String = "hello") async {
        let embedder = MiniLMEmbedder()
        _ = try? await embedder.embed(sampleText)
        _ = try? await embedder.prewarm()
    }
    #endif
}
