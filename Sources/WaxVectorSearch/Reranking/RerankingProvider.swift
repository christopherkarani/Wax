import Foundation

/// Scores how relevant each document is to a query, so a search can reorder its top candidates.
///
/// A reranker reads the query and the document together (a cross-encoder, for example), which
/// is slower than comparing embeddings but more accurate. Wax calls it once per search with the
/// full text of the top candidates.
public protocol RerankingProvider: Sendable {
    /// Returns one score per document, in the order given; a higher score means more relevant.
    ///
    /// Scores only need to be comparable within one call. Return exactly `documents.count`
    /// finite values: Wax throws if the count differs or a score is NaN or infinite.
    func scores(query: String, documents: [String]) async throws -> [Float]
}
