#if WaxRepo && os(macOS)
import SwiftTUI

/// Convenience entry point for the SwiftTUI interactive search application.
///
/// Usage:
/// ```swift
/// let store = try await RepoStore(storeURL: url)
/// let app = SearchApp(store: store)
/// app.run()   // blocks on dispatchMain
/// ```
///
/// The `SearchCommand` creates `SearchViewModel` and `Application` directly
/// for finer control (e.g. pre-populating a query). This wrapper provides
/// a simpler API for callers that just want to launch the TUI.
struct SearchApp {
    private let viewModel: SearchViewModel

    init(store: RepoStore, topK: Int = 10) {
        self.viewModel = SearchViewModel(store: store, topK: topK)
    }

    /// Launch the terminal UI. This call blocks until the user quits (Ctrl-D).
    func run() {
        let rootView = SearchView(viewModel: viewModel)
        let application = Application(rootView: rootView)
        application.start()
    }
}
#endif
