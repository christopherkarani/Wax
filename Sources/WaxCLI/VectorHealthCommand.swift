import ArgumentParser
import Foundation
import Wax

struct VectorHealthCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "vector-health",
        abstract: "Verify vector search health against the target store"
    )

    @OptionGroup var store: VectorStoreOptions

    func runAsync() async throws {
        let primary = try await checkPrimaryStore()
        let healthy = primary.vectorSearchEnabled
            && primary.embedderIdentity != nil
            && primary.framesWithoutVectors == 0
            && primary.canary.passed

        switch store.format {
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
                    "frameCount": primary.frameCount,
                    "framesWithoutVectors": primary.framesWithoutVectors,
                    "embedder": embedder,
                ],
                "semanticProbe": [
                    "passed": primary.canary.passed,
                    "vectorSourceSeen": primary.canary.vectorSourceSeen,
                    "expectedDocMatched": primary.canary.expectedDocMatched,
                    "topPreview": primary.canary.topPreview,
                    "topSources": primary.canary.topSources,
                    "queryEmbeddingState": primary.canary.queryEmbeddingState.rawValue,
                    "effectiveMode": primary.canary.effectiveMode.diagnosticsSummary,
                    "targetStore": true,
                ],
            ])
        case .text:
            print("Vector health: \(healthy ? "PASS" : "FAIL")")
            print("Store: \(primary.path)")
            print("Vector search: \(primary.vectorSearchEnabled ? "enabled" : "disabled")")
            print("Frames without vectors: \(primary.framesWithoutVectors)")
            if let identity = primary.embedderIdentity {
                let provider = identity.provider ?? "unknown"
                let model = identity.model ?? "unknown"
                let dims = identity.dimensions.map { String($0) } ?? "?"
                print("Embedder: \(provider)/\(model) (\(dims)d)")
            } else {
                print("Embedder: none")
            }
            print("Primary-store canary: \(primary.canary.passed ? "PASS" : "FAIL")")
            print("Canary vector source seen: \(primary.canary.vectorSourceSeen ? "yes" : "no")")
            print("Canary query embedding: \(primary.canary.queryEmbeddingState.rawValue)")
            if !primary.canary.topPreview.isEmpty {
                print("Canary top preview: \(primary.canary.topPreview)")
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
        let frameCount: UInt64
        let framesWithoutVectors: UInt64
        let canary: SemanticProbeResult
    }

    struct SemanticProbeResult {
        let passed: Bool
        let vectorSourceSeen: Bool
        let expectedDocMatched: Bool
        let topPreview: String
        let topSources: [String]
        let queryEmbeddingState: RAGContext.QueryEmbeddingState
        let effectiveMode: SearchMode
    }

    func checkPrimaryStore() async throws -> PrimaryStoreCheck {
        let url = try StoreSession.resolveURL(store.storePath)
        try failFastIfStoreHeld(at: url)
        return try await StoreSession.withOpen(
            at: url,
            noEmbedder: store.noEmbedder,
            embedderChoice: store.embedder,
            embedderTuning: store.embedderTuning,
            requireVector: true
        ) { memory in
            let stats = await memory.runtimeStats()
            let execution = try await memory.searchExecution(
                query: "wax vector health canary",
                mode: .vectorOnly,
                topK: 5,
                frameFilter: nil,
                timeRange: nil
            )
            let vectorSourceSeen = execution.hits.contains { $0.sources.contains(.vector) }
            let canaryPassed = execution.effectiveMode == .vectorOnly
                && execution.queryEmbeddingState == .available
                // An empty store has no frame to return, but the actual target
                // query still proves the provider and vector engine are live.
                && (stats.frameCount == 0 || vectorSourceSeen)
            return PrimaryStoreCheck(
                path: stats.storeURL.path,
                vectorSearchEnabled: stats.vectorSearchEnabled,
                embedderIdentity: stats.embedderIdentity,
                frameCount: stats.frameCount,
                framesWithoutVectors: stats.framesWithoutVectors,
                canary: SemanticProbeResult(
                    passed: canaryPassed,
                    vectorSourceSeen: vectorSourceSeen,
                    expectedDocMatched: !execution.hits.isEmpty,
                    topPreview: execution.hits.first?.previewText ?? "",
                    topSources: (execution.hits.first?.sources ?? []).map(\.rawValue),
                    queryEmbeddingState: execution.queryEmbeddingState,
                    effectiveMode: execution.effectiveMode
                )
            )
        }
    }

    func failFastIfStoreHeld(at url: URL) throws {
        guard try StoreLockProbe.tryExclusiveAccess(at: url) else {
            throw CLIError(
                "another process holds an exclusive lock on this store; if a broker is attached, use waxmcp stats / attach instead of waiting"
            )
        }
    }
}
