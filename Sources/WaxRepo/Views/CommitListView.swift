#if WaxRepo && os(macOS)
import SwiftTUI

/// Indexed wrapper for use with SwiftTUI ForEach.
private struct IndexedResult: Hashable {
    let index: Int
    let shortHash: String
    let subject: String
    let author: String
    let date: String

    func hash(into hasher: inout Hasher) {
        hasher.combine(index)
    }

    static func == (lhs: IndexedResult, rhs: IndexedResult) -> Bool {
        lhs.index == rhs.index
    }
}

/// Scrollable list of commit search results.
///
/// Each row shows the short hash, subject, author, and date.
/// The currently selected row is highlighted with a marker.
struct CommitListView: View {
    let results: [CommitSearchResult]
    let selectedIndex: Int
    let searchTime: String
    let onSelect: (Int) -> Void

    var body: some View {
        VStack {
            if results.isEmpty {
                Text("No results")
                    .foregroundColor(.gray)
            } else {
                ScrollView {
                    ForEach(indexedResults, id: \.index) { item in
                        Button(action: { onSelect(item.index) }) {
                            commitRow(item, isSelected: item.index == selectedIndex)
                        }
                    }
                }
                statusBar
            }
        }
    }

    private var indexedResults: [IndexedResult] {
        results.enumerated().map { index, result in
            IndexedResult(
                index: index,
                shortHash: result.shortHash,
                subject: result.subject,
                author: result.author,
                date: result.date
            )
        }
    }

    private func commitRow(_ item: IndexedResult, isSelected: Bool) -> some View {
        HStack {
            Text(isSelected ? ">" : " ")
                .foregroundColor(.yellow)
            Text(item.shortHash)
                .foregroundColor(.cyan)
            Text(truncate(item.subject, to: 48))
                .foregroundColor(isSelected ? .white : .default)
            Text(item.date)
                .foregroundColor(.gray)
        }
    }

    private var statusBar: some View {
        HStack {
            Text("\(results.count) results")
                .foregroundColor(.gray)
            Text(searchTime)
                .foregroundColor(.gray)
        }
    }

    private func truncate(_ text: String, to maxLength: Int) -> String {
        if text.count <= maxLength { return text }
        return String(text.prefix(maxLength - 1)) + "~"
    }
}
#endif
