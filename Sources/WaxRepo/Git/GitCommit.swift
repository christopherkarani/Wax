import Foundation

/// A parsed git commit with its diff content.
struct GitCommit: Sendable {
    let hash: String
    let shortHash: String
    let author: String
    let date: String
    let subject: String
    let body: String
    let diff: String

    /// The content string ingested into Wax for embedding and search.
    var ingestContent: String {
        var parts = [subject]
        let trimmedBody = body.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedBody.isEmpty {
            parts.append("")
            parts.append(trimmedBody)
        }
        if !diff.isEmpty {
            parts.append("")
            parts.append("---")
            parts.append(diff.prefix(8192).description)
        }
        return parts.joined(separator: "\n")
    }
}
