import ArgumentParser
import Foundation
import Wax

struct RecallCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "recall",
        abstract: "Recall memories matching a query"
    )

    @OptionGroup var store: VectorStoreOptions

    @Argument(help: "Query to recall against")
    var query: String

    @Option(name: .customLong("limit"), help: "Maximum results to return (1-100, default 5)")
    var limit: Int = 5

    func runAsync() async throws {
        guard limit >= 1, limit <= 100 else {
            throw CLIError("limit must be between 1 and 100")
        }

        if AgentDaemonPolicy.shouldUseDaemonForRecall(store: store),
           let response = try AgentDaemonTransport.perform(
               request: CLIDaemonRequest(
                   id: nil,
                   command: "recall",
                   content: nil,
                   query: query,
                   metadata: nil,
                   mode: nil,
                   topK: nil,
                   limit: limit
               ),
               storePath: store.storePath,
               embedderChoice: store.embedder
           ) {
            guard response.ok else {
                throw CLIError(response.error ?? "Daemon recall failed")
            }
            guard case .recall(let daemonQuery, let totalTokens, let items)? = response.payload else {
                throw CLIError("Daemon recall returned an unexpected payload")
            }

            switch store.format {
            case .json:
                let encodedItems: [[String: Any]] = items.map { item in
                    [
                        "rank": item.rank,
                        "kind": item.kind ?? "",
                        "frameId": item.frameId,
                        "score": item.score,
                        "text": item.text ?? "",
                    ]
                }
                printJSON([
                    "query": daemonQuery,
                    "totalTokens": totalTokens,
                    "count": encodedItems.count,
                    "items": encodedItems,
                ])
            case .text:
                print("Query: \(daemonQuery)")
                print("Total tokens: \(totalTokens)")
                for item in items {
                    print(
                        "\(item.rank). [\(item.kind ?? "unknown")] frame=\(item.frameId) score=\(String(format: "%.4f", item.score)) \(item.text ?? "")"
                    )
                }
            }
            return
        }

        let url = try StoreSession.resolveURL(store.storePath)
        try await StoreSession.withOpen(
            at: url,
            noEmbedder: store.noEmbedder,
            embedderChoice: store.embedder,
            requireVector: store.requireVector
        ) { memory in
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
}
