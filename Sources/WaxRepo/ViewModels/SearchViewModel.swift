import Foundation
#if WaxRepo && os(macOS)
import Combine

/// Async bridge between the Wax-powered RepoStore and the SwiftTUI view layer.
///
/// `@MainActor` ensures all `@Published` property mutations happen on the main
/// dispatch queue, which SwiftTUI's run loop already uses. Callers from async
/// contexts use `await` to hop to the main actor before mutating state.
@MainActor
final class SearchViewModel: ObservableObject {

    // MARK: - Published State

    @Published var query: String = ""
    @Published var results: [CommitSearchResult] = []
    @Published var selectedIndex: Int = 0
    @Published var isSearching: Bool = false
    @Published var selectedDiff: String = ""
    @Published var searchTime: String = ""
    @Published var errorMessage: String?

    // MARK: - Dependencies

    private let store: RepoStore
    private let topK: Int

    // MARK: - Init

    init(store: RepoStore, topK: Int = 10) {
        self.store = store
        self.topK = topK
    }

    // MARK: - Actions

    /// Update the query text and trigger a search.
    /// Called from the search command when a query argument is provided.
    func updateQuery(_ newQuery: String) async {
        let trimmed = newQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        query = trimmed
        isSearching = true
        errorMessage = nil
        await executeSearch(trimmed)
    }

    /// Perform a semantic search against the store.
    /// Called from the SwiftTUI TextField callback (already on main queue).
    func performSearch(_ queryText: String) {
        let trimmed = queryText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        query = trimmed
        isSearching = true
        errorMessage = nil

        Task {
            await executeSearch(trimmed)
        }
    }

    /// Move the selection cursor up or down, clamped to valid bounds.
    func moveSelection(by offset: Int) {
        guard !results.isEmpty else { return }
        let newIndex = min(max(selectedIndex + offset, 0), results.count - 1)
        guard newIndex != selectedIndex else { return }
        selectedIndex = newIndex
        selectedDiff = results[newIndex].previewText
    }

    /// Load the diff preview for a specific result by index.
    func selectResult(at index: Int) {
        guard results.indices.contains(index) else { return }
        selectedIndex = index
        selectedDiff = results[index].previewText
    }

    // MARK: - Private

    private func executeSearch(_ trimmed: String) async {
        let start = ContinuousClock.now
        do {
            let hits = try await store.search(query: trimmed, topK: topK)
            let elapsed = ContinuousClock.now - start
            // 10^15 attoseconds per millisecond
            let ms = elapsed.components.seconds * 1000
                + Int64(elapsed.components.attoseconds / 1_000_000_000_000_000)

            results = hits
            selectedIndex = 0
            selectedDiff = hits.first?.previewText ?? ""
            searchTime = "\(ms)ms"
            isSearching = false
        } catch {
            errorMessage = error.localizedDescription
            isSearching = false
        }
    }
}
#endif
