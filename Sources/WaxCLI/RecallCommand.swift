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

        if AgentBrokerPolicy.shouldUseBroker(store: store) {
            let configuration = try AgentBrokerCLI.configuration(
                storePath: store.storePath,
                embedderChoice: store.embedder.rawValue,
                noEmbedder: store.noEmbedder,
                requireVector: store.requireVector,
                embedderTuning: store.embedderTuning
            )
            let result = try await AgentBrokerClient.performRecall(
                query: query,
                limit: limit,
                configuration: configuration
            )
            render(format: store.format, query: result.query, totalTokens: result.totalTokens, rows: result.items)
            return
        }

        let url = try StoreSession.resolveURL(store.storePath)
        try await StoreSession.withOpen(
            at: url,
            noEmbedder: store.noEmbedder,
            embedderChoice: store.embedder,
            embedderTuning: store.embedderTuning,
            requireVector: store.requireVector
        ) { memory in
            let context = try await memory.recall(query: query, frameFilter: nil)
            let rows = context.items.prefix(limit).enumerated().map { index, item in
                BrokerRecallRow(
                    rank: index + 1,
                    kind: "\(item.kind)",
                    frameId: item.frameId,
                    score: Double(item.score),
                    text: item.text
                )
            }
            render(format: store.format, query: context.query, totalTokens: context.totalTokens, rows: rows)
        }
    }

    private func render(format: OutputFormat, query: String, totalTokens: Int, rows: [BrokerRecallRow]) {
        switch format {
        case .json:
            printJSON([
                "query": query,
                "totalTokens": totalTokens,
                "count": rows.count,
                "items": rows.map { row in
                    [
                        "rank": row.rank,
                        "kind": row.kind ?? "",
                        "frameId": row.frameId,
                        "score": row.score,
                        "text": row.text,
                    ] as [String: Any]
                },
            ])
        case .text:
            print("Query: \(query)")
            print("Total tokens: \(totalTokens)")
            for row in rows {
                print(
                    "\(row.rank). [\(row.kind ?? "unknown")] frame=\(row.frameId) score=\(String(format: "%.4f", row.score)) \(row.text)"
                )
            }
        }
    }
}
