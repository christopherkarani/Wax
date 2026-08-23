import ArgumentParser
import Foundation
import Wax

struct SearchCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "search",
        abstract: "Search memory frames by text, vector, or hybrid mode"
    )

    @OptionGroup var store: VectorStoreOptions

    @Argument(help: "Search query")
    var query: String

    @Option(name: .customLong("mode"), help: "Search mode: text, vector, or hybrid (default: text)")
    var mode: String = "text"

    @Option(name: .customLong("top-k"), help: "Maximum results to return (1-200, default 10)")
    var topK: Int = 10

    func runAsync() async throws {
        let modeLower = mode.lowercased()
        guard modeLower == "text" || modeLower == "vector" || modeLower == "hybrid" else {
            throw CLIError("mode must be one of: text, vector, hybrid")
        }
        guard topK >= 1, topK <= 200 else {
            throw CLIError("top-k must be between 1 and 200")
        }

        let searchMode: Memory.RetrievalMode
        let requireVector = store.requireVector || modeLower == "vector" || modeLower == "hybrid"
        switch modeLower {
        case "text":
            searchMode = .textOnly
        case "vector":
            searchMode = .vectorOnly
        case "hybrid":
            searchMode = .hybrid(alpha: 0.5)
        default:
            throw CLIError("mode must be one of: text, vector, hybrid")
        }

        if AgentBrokerPolicy.shouldUseBroker(store: store) {
            let configuration = try AgentBrokerCLI.configuration(
                storePath: store.storePath,
                embedderChoice: store.embedder.rawValue,
                noEmbedder: store.noEmbedder,
                requireVector: requireVector,
                embedderTuning: store.embedderTuning
            )
            let result = try await AgentBrokerClient.performSearch(
                query: query,
                mode: modeLower,
                topK: topK,
                configuration: configuration
            )
            render(format: store.format, rows: result.items)
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
            let rows = hits.enumerated().map { index, hit in
                BrokerSearchRow(
                    rank: index + 1,
                    frameId: hit.frameId,
                    score: Double(hit.score),
                    sources: hit.sources.map(\.rawValue),
                    preview: hit.previewText ?? ""
                )
            }
            render(format: store.format, rows: rows)
        }
    }

    private func render(format: OutputFormat, rows: [BrokerSearchRow]) {
        switch format {
        case .json:
            printJSON([
                "count": rows.count,
                "items": rows.map { row in
                    [
                        "rank": row.rank,
                        "frameId": row.frameId,
                        "score": row.score,
                        "sources": row.sources,
                        "preview": row.preview,
                    ] as [String: Any]
                },
            ])
        case .text:
            if rows.isEmpty {
                print("No results.")
            } else {
                for row in rows {
                    print(
                        "\(row.rank). frame=\(row.frameId) score=\(String(format: "%.4f", row.score)) sources=[\(row.sources.joined(separator: ","))] \(row.preview)"
                    )
                }
            }
        }
    }
}
