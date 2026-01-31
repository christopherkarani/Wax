import Foundation

/// Query constraints for structured memory traversal.
public struct StructuredMemoryQueryContext: Sendable, Equatable {
    public var asOf: StructuredMemoryAsOf
    public var maxResults: Int
    public var maxTraversalEdges: Int
    public var maxDepth: Int

    public init(
        asOf: StructuredMemoryAsOf,
        maxResults: Int,
        maxTraversalEdges: Int,
        maxDepth: Int
    ) {
        self.asOf = asOf
        self.maxResults = maxResults
        self.maxTraversalEdges = maxTraversalEdges
        self.maxDepth = maxDepth
    }
}
