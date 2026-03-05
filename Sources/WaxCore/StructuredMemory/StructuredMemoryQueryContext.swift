import Foundation

/// Query constraints for structured memory traversal.
package struct StructuredMemoryQueryContext: Sendable, Equatable {
    package var asOf: StructuredMemoryAsOf
    package var maxResults: Int
    package var maxTraversalEdges: Int
    package var maxDepth: Int

    package init(
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
