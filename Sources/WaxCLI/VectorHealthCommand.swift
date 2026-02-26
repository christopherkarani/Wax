import ArgumentParser
import Foundation
import Wax

struct VectorHealthCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "vector-health",
        abstract: "Verify MiniLM vector search health with a semantic probe"
    )

    @Option(name: .customLong("store-path"), help: "Path to Wax memory store (.wax)")
    var storePath: String = StoreSession.defaultStorePath

    @Option(name: .customLong("format"), help: "Output format: json (default) or text")
    var format: OutputFormat = .json

    func runAsync() async throws {
        let primary = try await checkPrimaryStore()
        let probe = try await runSemanticProbe()
        let healthy = primary.vectorSearchEnabled && primary.embedderIdentity != nil && probe.passed

        switch format {
        case .json:
            let embedder: Any = {
                guard let identity = primary.embedderIdentity else { return NSNull() }
                return [
                    "provider": identity.provider ?? "",
                    "model": identity.model ?? "",
                    "dimensions": identity.dimensions ?? 0,
                    "normalized": identity.normalized ?? false,
                ] as [String: Any]
            }()

            printJSON([
                "healthy": healthy,
                "primaryStore": [
                    "path": primary.path,
                    "vectorSearchEnabled": primary.vectorSearchEnabled,
                    "embedder": embedder,
                ],
                "semanticProbe": [
                    "passed": probe.passed,
                    "vectorSourceSeen": probe.vectorSourceSeen,
                    "expectedDocMatched": probe.expectedDocMatched,
                    "topPreview": probe.topPreview,
                    "topSources": probe.topSources,
                ],
            ])
        case .text:
            print("Vector health: \(healthy ? "PASS" : "FAIL")")
            print("Store: \(primary.path)")
            print("Vector search: \(primary.vectorSearchEnabled ? "enabled" : "disabled")")
            if let identity = primary.embedderIdentity {
                let provider = identity.provider ?? "unknown"
                let model = identity.model ?? "unknown"
                let dims = identity.dimensions.map { String($0) } ?? "?"
                print("Embedder: \(provider)/\(model) (\(dims)d)")
            } else {
                print("Embedder: none")
            }
            print("Semantic probe: \(probe.passed ? "PASS" : "FAIL")")
            print("Probe vector source seen: \(probe.vectorSourceSeen ? "yes" : "no")")
            print("Probe expected doc matched: \(probe.expectedDocMatched ? "yes" : "no")")
            if !probe.topPreview.isEmpty {
                print("Probe top preview: \(probe.topPreview)")
            }
        }

        if !healthy {
            throw ExitCode.failure
        }
    }
}

private extension VectorHealthCommand {
    struct PrimaryStoreCheck {
        let path: String
        let vectorSearchEnabled: Bool
        let embedderIdentity: EmbeddingIdentity?
    }

    struct SemanticProbeResult {
        let passed: Bool
        let vectorSourceSeen: Bool
        let expectedDocMatched: Bool
        let topPreview: String
        let topSources: [String]
    }

    func checkPrimaryStore() async throws -> PrimaryStoreCheck {
        let url = try StoreSession.resolveURL(storePath)
        let memory = try await StoreSession.open(at: url, noEmbedder: false)
        defer { Task { try? await memory.close() } }

        let stats = await memory.runtimeStats()
        return PrimaryStoreCheck(
            path: stats.storeURL.path,
            vectorSearchEnabled: stats.vectorSearchEnabled,
            embedderIdentity: stats.embedderIdentity
        )
    }

    func runSemanticProbe() async throws -> SemanticProbeResult {
        let probeURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("wax-vector-health-\(UUID().uuidString).wax")
        let memory = try await StoreSession.open(at: probeURL, noEmbedder: false)
        defer {
            Task { try? await memory.close() }
            try? FileManager.default.removeItem(at: probeURL)
        }

        let expectedDocument = "An automobile needs periodic maintenance and tire rotation."
        try await memory.remember(expectedDocument, metadata: ["probe": "vector-health"])
        try await memory.remember(
            "Bananas are a tropical fruit often eaten in smoothies.",
            metadata: ["probe": "vector-health"]
        )
        try await memory.flush()

        let hits = try await memory.search(
            query: "car service",
            mode: .hybrid(alpha: 0.5),
            topK: 3,
            frameFilter: nil
        )

        let topHit = hits.first
        let vectorSourceSeen = hits.contains(where: { $0.sources.contains(.vector) })
        let expectedDocMatched = hits.contains {
            ($0.previewText ?? "").localizedCaseInsensitiveContains("automobile")
        }
        let topPreview = topHit?.previewText ?? ""
        let topSources = (topHit?.sources ?? []).map(\.rawValue)

        return SemanticProbeResult(
            passed: vectorSourceSeen && expectedDocMatched,
            vectorSourceSeen: vectorSourceSeen,
            expectedDocMatched: expectedDocMatched,
            topPreview: topPreview,
            topSources: topSources
        )
    }
}
