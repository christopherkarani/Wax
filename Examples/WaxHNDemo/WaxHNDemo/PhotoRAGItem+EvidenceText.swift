import Wax

extension PhotoRAGItem: Identifiable {
    public var id: String { assetID }

    /// Text snippets from `.text` evidence, or `summaryText` when none exist.
    var evidenceText: String {
        let snippets = evidence.compactMap { evidence -> String? in
            guard case .text(let snippet) = evidence else { return nil }
            let trimmed = snippet?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return trimmed.isEmpty ? nil : trimmed
        }
        if snippets.isEmpty {
            return summaryText
        }
        return snippets.joined(separator: "\n")
    }
}
