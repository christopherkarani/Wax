import Foundation

extension Memory {
    @available(*, deprecated, message: "Use search(_:strategy:reranker:options:)")
    @_disfavoredOverload
    public func search<S: SearchStrategy>(
        _ query: String,
        strategy: S,
        options: SearchOptions = .default
    ) async throws -> Results {
        try await search(query, strategy: strategy as any SearchStrategy, options: options)
    }

    @available(*, deprecated, message: "Use search(_:strategy:reranker:options:)")
    @_disfavoredOverload
    public func search<S: SearchStrategy, R: ResultReranker>(
        _ query: String,
        strategy: S,
        options: SearchOptions = .default,
        reranker: R
    ) async throws -> Results {
        try await search(
            query,
            strategy: strategy as any SearchStrategy,
            reranker: reranker as any ResultReranker,
            options: options
        )
    }
}
