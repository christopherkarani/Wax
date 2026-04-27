import Foundation

#if MiniLMEmbeddings && canImport(WaxVectorSearchMiniLM) && canImport(CoreML)
import WaxVectorSearchMiniLM
#endif

package enum WaxPrewarm {
    package static func tokenizer() async {
        do {
            _ = try await TokenCounter.shared()
        } catch {
            WaxDiagnostics.logSwallowed(
                error,
                context: "wax prewarm tokenizer",
                fallback: "cold start on first use"
            )
        }
    }

    #if MiniLMEmbeddings && canImport(WaxVectorSearchMiniLM) && canImport(CoreML)
    @available(macOS 15.0, iOS 18.0, *)
    package static func miniLM(sampleText: String = "hello") async throws {
        let embedder = try MiniLMEmbedder()
        try await embedder.prewarm()
    }
    #endif
}
