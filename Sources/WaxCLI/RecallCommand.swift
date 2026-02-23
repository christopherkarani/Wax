import ArgumentParser
import Foundation
import Wax

struct RecallCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "recall",
        abstract: "Recall memories matching a query"
    )

    @OptionGroup var store: StoreOptions

    @Argument(help: "Query to recall against")
    var query: String

    @Option(name: .customLong("limit"), help: "Maximum results to return (1-100, default 5)")
    var limit: Int = 5

    func runAsync() async throws {
        guard limit >= 1, limit <= 100 else {
            throw CLIError("limit must be between 1 and 100")
        }

        let url = try StoreSession.resolveURL(store.storePath)
        let memory = try await StoreSession.open(at: url, noEmbedder: store.noEmbedder)
        defer { Task { try? await memory.close() } }

        let context = try await memory.recall(query: query, frameFilter: nil)
        let selected = context.items.prefix(limit)

        switch store.format {
        case .json:
            let items: [[String: Any]] = selected.enumerated().map { index, item in
                [
                    "rank": index + 1,
                    "kind": "\(item.kind)",
                    "frameId": item.frameId,
                    "score": Double(item.score),
                    "text": item.text,
                ]
            }
            printJSON([
                "query": context.query,
                "totalTokens": context.totalTokens,
                "count": items.count,
                "items": items,
            ])
        case .text:
            print("Query: \(context.query)")
            print("Total tokens: \(context.totalTokens)")
            for (index, item) in selected.enumerated() {
                print(
                    "\(index + 1). [\(item.kind)] frame=\(item.frameId) score=\(String(format: "%.4f", item.score)) \(item.text)"
                )
            }
        }
    }
}
