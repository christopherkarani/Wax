import SwiftUI
import Wax

struct TextResultsPane: View {
    let hits: [RAGContext.Item]
    let emptyTitle: String
    let emptyBody: String

    var body: some View {
        if hits.isEmpty {
            ContentUnavailableView(emptyTitle, systemImage: "doc.text.magnifyingglass", description: Text(emptyBody))
        } else {
            List(hits, id: \.frameId) { item in
                VStack(alignment: .leading, spacing: 4) {
                    Text(item.metadata["source_filename"] ?? item.metadata["source_kind"] ?? "Memory")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(item.text)
                        .font(.body)
                        .lineLimit(5)
                        .textSelection(.enabled)
                }
                .padding(.vertical, 4)
            }
            .listStyle(.plain)
        }
    }
}
