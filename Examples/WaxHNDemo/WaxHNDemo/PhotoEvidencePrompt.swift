import Wax

enum PhotoEvidencePrompt {
    static func make(query: String, items: [PhotoRAGItem]) -> String {
        let evidence = items
            .map { item in "[\(item.assetID)]\n\(item.summaryText)" }
            .joined(separator: "\n\n")
        return """
        Answer using only this on-device photo evidence. If the evidence does not contain the answer, say you cannot find it.

        <photo_evidence>
        \(evidence)
        </photo_evidence>

        Question: \(query)
        """
    }
}
