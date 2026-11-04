import Foundation
#if MiniLMEmbeddings && canImport(WaxVectorSearchMiniLM) && canImport(CoreML)
import WaxVectorSearchMiniLM
#endif

/// Ingest chunk sizing for the MiniLM embedder.
///
/// all-MiniLM-L6-v2 truncates its input at 256 WordPiece tokens, [CLS] and [SEP] included, so
/// the 400 cl100k-token general default lost every chunk's tail from its vector. Chunks are
/// cut in cl100k tokens. Measured with the model's WordPiece tokenizer on this repo's docs,
/// Swift source, JSON and shell scripts, WordPiece runs 0.94-1.28x longer at the median and at
/// most 1.41x; 254 content tokens / 1.41 = 180. URL- and HTML-dense text reaches ~1.95x, so
/// `fit` re-splits any chunk that still overflows, using that same tokenizer.
package enum MiniLMChunkSizing {
    package static let inputTokenLimit = 256
    package static let chunking = ChunkingStrategy.tokenCount(targetTokens: 180, overlapTokens: 18)

    /// `true` for any MiniLM revision's identity model name.
    package static func isMiniLM(model: String?) -> Bool {
        model?.lowercased().hasPrefix("minilm") == true
    }

    /// Re-splits chunks that would exceed the MiniLM input window. A no-op when the MiniLM
    /// tokenizer is not built in (MiniLM cannot embed in that build either).
    package static func fit(_ chunks: [String]) async -> [String] {
#if MiniLMEmbeddings && canImport(WaxVectorSearchMiniLM) && canImport(CoreML)
        guard let tokenizer else { return chunks }
        return await TextChunker.fit(chunks, inputTokenLimit: inputTokenLimit) {
            tokenizer.tokenize(text: $0).count + 2
        }
#else
        return chunks
#endif
    }

#if MiniLMEmbeddings && canImport(WaxVectorSearchMiniLM) && canImport(CoreML)
    private static let tokenizer: BertTokenizer? = {
        do {
            return try BertTokenizer()
        } catch {
            WaxDiagnostics.logSwallowed(
                error,
                context: "MiniLM chunk sizing tokenizer",
                fallback: "chunks keep the cl100k target; tails past 256 tokens are not embedded"
            )
            return nil
        }
    }()
#endif
}

extension OrchestratorConfig {
    /// Sizes ingest chunks for the embedder that will embed them. The general default target
    /// drops to ``MiniLMChunkSizing/chunking`` for MiniLM; an explicit target is kept, and
    /// every MiniLM chunk is still fitted to the input window.
    package func sizingChunks(forEmbedderModel model: String?) -> OrchestratorConfig {
        guard MiniLMChunkSizing.isMiniLM(model: model) else { return self }
        var sized = self
        sized.fitsChunksToMiniLMInput = true
        if sized.chunking == Self.defaultChunking {
            sized.chunking = MiniLMChunkSizing.chunking
        }
        return sized
    }

    /// Built-in requests size chunks before the provider finishes loading, so text-only saves
    /// made meanwhile are already sized for the vectors a backfill writes later.
    package func sizingChunks(for provider: BuiltInEmbeddingProvider) -> OrchestratorConfig {
        provider == .miniLM ? sizingChunks(forEmbedderModel: "MiniLMAll-mean") : self
    }
}
