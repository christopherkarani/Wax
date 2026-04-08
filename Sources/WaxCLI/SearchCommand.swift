import ArgumentParser
import Foundation
import Wax

struct SearchCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "search",
        abstract: "Search memory frames by text or hybrid mode"
    )

    @OptionGroup var store: VectorStoreOptions

    @Argument(help: "Search query")
    var query: String

    @Option(name: .customLong("mode"), help: "Search mode: text or hybrid (default: text)")
    var mode: String = "text"

    @Option(name: .customLong("top-k"), help: "Maximum results to return (1-200, default 10)")
    var topK: Int = 10

    func runAsync() async throws {
        let modeLower = mode.lowercased()
        guard modeLower == "text" || modeLower == "hybrid" else {
            throw CLIError("mode must be one of: text, hybrid")
        }
        guard topK >= 1, topK <= 200 else {
            throw CLIError("top-k must be between 1 and 200")
        }

        let searchMode: MemoryOrchestrator.DirectSearchMode
        let requireVector = store.requireVector || modeLower == "hybrid"
        switch modeLower {
        case "text":
            searchMode = .text
        case "hybrid":
            searchMode = .hybrid(alpha: 0.5)
        default:
            throw CLIError("mode must be one of: text, hybrid")
        }

        if AgentBrokerPolicy.shouldUseBroker(store: store) {
            let response = try await AgentBrokerCLI.perform(
                command: "search",
                arguments: [
                    "query": .string(query),
                    "mode": .string(modeLower),
                    "topK": .from(topK),
                ],
                storePath: store.storePath,
                embedderChoice: store.embedder.rawValue,
                noEmbedder: store.noEmbedder,
                requireVector: requireVector,
                embedderTuning: store.embedderTuning
            )
            let payload = try brokerPayloadObject(response)
            let items = brokerArray(payload, "results")
            let count = items.count

            switch store.format {
            case .json:
                let encodedItems: [[String: Any]] = items.compactMap { item in
                    guard let object = item.objectValue else { return nil }
                    return [
                        "rank": brokerInt(object, "rank") ?? 0,
                        "frameId": brokerInt64(object, "frameId") ?? 0,
                        "score": object["score"]?.doubleValue ?? 0,
                        "sources": brokerArray(object, "sources").compactMap(\.stringValue),
                        "preview": brokerString(object, "preview") ?? "",
                    ]
                }
                printJSON([
                    "count": count,
                    "items": encodedItems,
                ])
            case .text:
                if items.isEmpty {
                    print("No results.")
                } else {
                    for item in items {
                        guard let object = item.objectValue else { continue }
                        print(
                            "\(brokerInt(object, "rank") ?? 0). frame=\(brokerInt64(object, "frameId") ?? 0) score=\(String(format: "%.4f", object["score"]?.doubleValue ?? 0)) sources=[\(brokerArray(object, "sources").compactMap(\.stringValue).joined(separator: ","))] \(brokerString(object, "preview") ?? "")"
                        )
                    }
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
            requireVector: requireVector
        ) { memory in
            let hits = try await memory.search(query: query, mode: searchMode, topK: topK, frameFilter: nil)

            switch store.format {
            case .json:
                let items: [[String: Any]] = hits.enumerated().map { index, hit in
                    [
                        "rank": index + 1,
                        "frameId": hit.frameId,
                        "score": Double(hit.score),
                        "sources": hit.sources.map { $0.rawValue },
                        "preview": hit.previewText ?? "",
                    ]
                }
                printJSON([
                    "count": items.count,
                    "items": items,
                ])
            case .text:
                if hits.isEmpty {
                    print("No results.")
                } else {
                    for (index, hit) in hits.enumerated() {
                        let sources = hit.sources.map { $0.rawValue }.joined(separator: ",")
                        let preview = hit.previewText ?? ""
                        print(
                            "\(index + 1). frame=\(hit.frameId) score=\(String(format: "%.4f", hit.score)) sources=[\(sources)] \(preview)"
                        )
                    }
                }
            }
        }
    }
}
