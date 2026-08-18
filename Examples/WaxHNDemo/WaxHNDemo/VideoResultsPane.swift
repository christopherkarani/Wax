import SwiftUI
import Wax

struct VideoResultsPane: View {
    let hits: [VideoRAGItem]

    var body: some View {
        if hits.isEmpty {
            ContentUnavailableView(
                "Search Harbor clips",
                systemImage: "film",
                description: Text("The Harbor week videos load when you open this section.")
            )
        } else {
            List(hits, id: \.videoID.id) { item in
                VStack(alignment: .leading, spacing: 6) {
                    Text(item.videoID.id)
                        .font(.headline)
                    Text(item.summaryText)
                        .font(.body)
                        .lineLimit(4)
                    ForEach(item.segments, id: \.startMs) { segment in
                        if let snippet = segment.transcriptSnippet, !snippet.isEmpty {
                            Text(Self.timecode(segment.startMs) + "  " + snippet)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                        }
                    }
                }
                .padding(.vertical, 4)
            }
            .listStyle(.plain)
        }
    }

    private static func timecode(_ ms: Int64) -> String {
        let total = max(0, ms) / 1000
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}
