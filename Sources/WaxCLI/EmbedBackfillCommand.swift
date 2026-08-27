import ArgumentParser
import Foundation
import Wax
import WaxCore

struct EmbedBackfillCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "embed-backfill",
        abstract: "Embed live frames that have no vectors on a copy of a store"
    )

    @OptionGroup var store: VectorStoreOptions

    func validate() throws {
        try store.validate()
        guard store.directStore else {
            throw ValidationError("--direct-store is required for embed-backfill")
        }
        try CompactStorePathPolicy.refuseLiveFamily(
            CompactStorePathPolicy.expandedURL(store.storePath),
            command: "embed-backfill"
        )
    }

    func runAsync() async throws {
        let url = try StoreSession.resolveURL(store.storePath)
        try failFastIfStoreHeld(at: url)

        if store.noEmbedder {
            throw CLIError("embed-backfill requires an embedder; --no-embedder fails closed")
        }

        do {
            try await StoreSession.withOpen(
                at: url,
                noEmbedder: false,
                embedderChoice: store.embedder,
                embedderTuning: store.embedderTuning,
                requireVector: true
            ) { memory in
                try await memory.waitUntilReadyForRemember()
                let before = await memory.runtimeStats()
                let examined = before.framesWithoutVectors
                let embedded = try await memory.backfillUnembedded()
                try await memory.flush()
                let after = await memory.runtimeStats()
                let payload: [String: Any] = [
                    "examined": examined,
                    "embedded": embedded,
                    "skippedAlreadyEmbedded": max(0, Int64(before.frameCount) - Int64(examined)),
                    "framesWithoutVectors": after.framesWithoutVectors,
                    "embeddingStatus": after.embeddingStatus.wireName,
                    "storePath": after.storeURL.path,
                ]
                switch store.format {
                case .json:
                    printJSON(payload)
                case .text:
                    print("Backfill examined \(examined) unembedded frame(s); embedded \(embedded).")
                    print("Frames without vectors: \(after.framesWithoutVectors)")
                    print("Embedding status: \(after.embeddingStatus.wireName)")
                }
            }
        } catch let error as WaxError {
            if case .missingEmbedder = error {
                throw CLIError("embed-backfill requires an embedder; none is attached")
            }
            throw error
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
