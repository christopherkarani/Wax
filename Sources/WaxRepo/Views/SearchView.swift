#if WaxRepo && os(macOS)
import SwiftTUI

/// Main search view composing the header, commit list, and diff preview.
///
/// Layout:
/// ```
///  ┌─ HeaderView ────────────────────────────┐
///  │  wax-repo | semantic git search         │
///  │  [enter query] ________________________ │
///  ├─────────────────────────────────────────┤
///  │  CommitListView    │  DiffPreviewView   │
///  │  > abc1234 fix..   │  + added line      │
///  │    def5678 add..   │  - removed line    │
///  │    ...             │  ...               │
///  └─────────────────────────────────────────┘
/// ```
struct SearchView: View {
    @ObservedObject var viewModel: SearchViewModel

    var body: some View {
        VStack {
            HeaderView(
                query: viewModel.query,
                isSearching: viewModel.isSearching,
                onSearch: { query in
                    viewModel.performSearch(query)
                }
            )
            HStack {
                CommitListView(
                    results: viewModel.results,
                    selectedIndex: viewModel.selectedIndex,
                    searchTime: viewModel.searchTime,
                    onSelect: { index in
                        viewModel.selectResult(at: index)
                    }
                )
                Divider()
                DiffPreviewView(diff: viewModel.selectedDiff)
            }
            if let error = viewModel.errorMessage {
                Text("Error: \(error)")
                    .foregroundColor(.red)
            }
        }
        .border(.rounded)
    }
}
#endif
