#if WaxRepo
import ArgumentParser
import Darwin
import Dispatch
import Foundation
import SwiftTUI

struct SearchCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "search",
        abstract: "Search git history semantically"
    )

    @Argument(help: "Search query (launches interactive TUI if omitted)")
    var query: String?

    @Option(name: .customLong("repo-path"), help: "Path to the git repository (default: current directory)")
    var repoPath: String = "."

    @Option(name: .customLong("top-k"), help: "Maximum number of results")
    var topK: Int = 10

    @Flag(name: .customLong("text-only"), help: "Use text search only (skip MiniLM embeddings)")
    var textOnly: Bool = false

    mutating func run() throws {
        let command = self
        Task(priority: .userInitiated) {
            do {
                try await command.runSearch()
            } catch {
                writeStderr("Error: \(error)")
                Darwin.exit(EXIT_FAILURE)
            }
        }

        dispatchMain()
    }

    private func runSearch() async throws {
        let repoRoot = try resolveRepoRoot(repoPath)
        let storePath = URL(fileURLWithPath: repoRoot)
            .appendingPathComponent(".wax-repo")
            .appendingPathComponent("store.mv2s")

        guard FileManager.default.fileExists(atPath: storePath.path) else {
            writeStderr("No index found. Run 'wax-repo index' first.")
            Darwin.exit(EXIT_FAILURE)
        }

        let store = try await RepoStore(storeURL: storePath, textOnly: textOnly)
        let viewModel = SearchViewModel(store: store, topK: topK)

        if let query {
            await viewModel.updateQuery(query)
        }

        Application(rootView: SearchView(viewModel: viewModel)).start()
    }
}

#endif
