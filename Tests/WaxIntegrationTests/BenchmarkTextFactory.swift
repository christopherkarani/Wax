// Deterministic benchmark-style documents. Kept apart from RAGBenchmarkSupport.swift,
// which needs Darwin XCTest's XCTMetric, so portable tests can use it on Linux.
struct BenchmarkTextFactory {
    let sentencesPerDocument: Int
    let baseSentences: [String] = [
        "Swift concurrency uses actors and tasks for safe parallelism.",
        "Vector search compares embeddings to find semantic neighbors.",
        "Hybrid search fuses lexical and vector signals for recall.",
        "Wax stores memory in a single Wax file with WAL safety.",
        "RAG pipelines rank, expand, and truncate context deterministically.",
        "Token budgets keep prompts stable across runs."
    ]

    var queryText: String {
        "Swift concurrency vector search"
    }

    func makeDocument(index: Int) -> String {
        var parts: [String] = []
        parts.reserveCapacity(sentencesPerDocument + 2)
        parts.append("Document \(index) about Wax RAG performance.")
        for offset in 0..<sentencesPerDocument {
            let sentence = baseSentences[(index + offset) % baseSentences.count]
            parts.append(sentence)
        }
        if index % 7 == 0 {
            parts.append("Swift performance and retrieval for doc \(index).")
        }
        return parts.joined(separator: " ")
    }
}
