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
            let response = try await AgentBrokerCLI.perform(
                command: "recall",
                arguments: [
                    "query": .string(query),
                    "limit": .from(limit),
                ],
                storePath: store.storePath,
                embedderChoice: store.embedder.rawValue,
                noEmbedder: store.noEmbedder,
                requireVector: store.requireVector,
                embedderTuning: store.embedderTuning
            )
            let payload = try brokerPayloadObject(response)
            let daemonQuery = brokerString(payload, "query") ?? query
            let totalTokens = brokerInt(payload, "total_tokens") ?? 0
            let items = brokerArray(payload, "results")

            switch store.format {
            case .json:
                let encodedItems: [[String: Any]] = items.compactMap { item in
                    guard let object = item.objectValue else { return nil }
                    return [
                        "rank": brokerInt(object, "rank") ?? 0,
                        "kind": brokerString(object, "kind") ?? "",
                        "frameId": brokerInt64(object, "frameId") ?? 0,
                        "score": object["score"]?.doubleValue ?? 0,
                        "text": brokerString(object, "text") ?? "",
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
                    guard let object = item.objectValue else { continue }
                    print(
                        "\(brokerInt(object, "rank") ?? 0). [\(brokerString(object, "kind") ?? "unknown")] frame=\(brokerInt64(object, "frameId") ?? 0) score=\(String(format: "%.4f", object["score"]?.doubleValue ?? 0)) \(brokerString(object, "text") ?? "")"
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
            embedderTuning: store.embedderTuning,
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
