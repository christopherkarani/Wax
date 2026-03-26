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
        switch modeLower {
        case "text":
            searchMode = .text
        case "hybrid":
            searchMode = .hybrid(alpha: 0.5)
        default:
            throw CLIError("mode must be one of: text, hybrid")
        }

        if AgentDaemonPolicy.shouldUseDaemonForSearch(store: store, mode: modeLower),
           let response = try AgentDaemonTransport.perform(
               request: CLIDaemonRequest(
                   id: nil,
                   command: "search",
                   content: nil,
                   query: query,
                   metadata: nil,
                   mode: modeLower,
                   topK: topK,
                   limit: nil
               ),
               storePath: store.storePath,
               embedderChoice: store.embedder
           ) {
            guard response.ok else {
                throw CLIError(response.error ?? "Daemon search failed")
            }
            guard case .search(let count, let items)? = response.payload else {
                throw CLIError("Daemon search returned an unexpected payload")
            }

            switch store.format {
            case .json:
                let encodedItems: [[String: Any]] = items.map { item in
                    [
                        "rank": item.rank,
                        "frameId": item.frameId,
                        "score": item.score,
                        "sources": item.sources,
                        "preview": item.preview ?? "",
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
                        print(
                            "\(item.rank). frame=\(item.frameId) score=\(String(format: "%.4f", item.score)) sources=[\(item.sources.joined(separator: ","))] \(item.preview ?? "")"
                        )
                    }
                }
            }
            return
        }

        let url = try StoreSession.resolveURL(store.storePath)
        let requireVector = store.requireVector || modeLower == "hybrid"
        try await StoreSession.withOpen(
            at: url,
            noEmbedder: store.noEmbedder,
            embedderChoice: store.embedder,
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
