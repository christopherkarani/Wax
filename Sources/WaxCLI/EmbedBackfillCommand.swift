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

    @Option(name: .customLong("output"), help: "Destination store path")
    var output: String

    @Flag(name: .customLong("overwrite"), help: "Replace an existing destination file after verification")
    var overwrite: Bool = false

    func validate() throws {
        try store.validate()
        guard store.directStore else {
            throw ValidationError("--direct-store is required for embed-backfill")
        }
        try StoreRepairSupport.validate(
            sourceRaw: store.storePath,
            destinationRaw: output,
            command: "embed-backfill"
        )
    }

    func runAsync() async throws {
        guard !store.noEmbedder else {
            throw CLIError("embed-backfill requires an embedder; --no-embedder fails closed")
        }
        let sourceURL = try StoreSession.resolveURL(store.storePath)
        let destinationURL = try StoreRepairSupport.destinationURL(from: output)
        try StoreRepairSupport.validate(
            source: sourceURL,
            destination: destinationURL,
            command: "embed-backfill"
        )
        try StoreRepairSupport.ensureRegularFileIfPresent(
            at: destinationURL,
            label: "output",
            command: "embed-backfill"
        )
        if FileManager.default.fileExists(atPath: destinationURL.path) {
            guard overwrite else {
                throw CLIError("output destination already exists; pass --overwrite to replace it")
            }
            try StoreRepairSupport.ensureDestinationUnlockedIfPresent(
                at: destinationURL,
                command: "embed-backfill"
            )
        }
        try failFastIfStoreHeld(at: sourceURL)

        let stagingURL = StoreRepairSupport.stagingURL(for: destinationURL)
        defer { try? FileManager.default.removeItem(at: stagingURL) }

        let sourceIdentity = StoreRepairSupport.identity(of: sourceURL)
        let sourceFingerprint = try StoreRepairSupport.copySource(
            from: sourceURL,
            to: stagingURL,
            overwrite: false
        )
        _ = try await StoreRepairSupport.verifyDeep(at: stagingURL)

        let result: (
            examined: UInt64,
            embedded: UInt64,
            remaining: UInt64,
            status: String
        ) = try await StoreSession.withOpen(
                at: stagingURL,
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
                return (
                    examined: examined,
                    embedded: embedded,
                    remaining: after.framesWithoutVectors,
                    status: after.embeddingStatus.wireName
                )
            }

        _ = try await StoreRepairSupport.verifyDeep(at: stagingURL)
        let sourceAfter = try StoreRepairSupport.fingerprint(of: sourceURL)
        guard sourceAfter == sourceFingerprint,
              StoreRepairSupport.identity(of: sourceURL) == sourceIdentity else {
            throw CLIError("source store changed during backfill; no repair output was published")
        }
        try StoreRepairSupport.validate(
            source: sourceURL,
            destination: destinationURL,
            command: "embed-backfill"
        )
        let promotion = try StoreRepairSupport.promoteVerifiedOutput(
            from: stagingURL,
            to: destinationURL,
            overwrite: overwrite,
            source: sourceURL
        )
        do {
            _ = try await StoreRepairSupport.verifyDeep(at: destinationURL)
            try StoreRepairSupport.finalizePromotion(promotion)
        } catch {
            try? StoreRepairSupport.rollbackPromotion(promotion)
            throw error
        }

        switch store.format {
        case .json:
            printJSON([
                "examined": result.examined,
                "embedded": result.embedded,
                "framesWithoutVectors": result.remaining,
                "embeddingStatus": result.status,
                "storePath": destinationURL.path,
                "sourceUnchanged": true,
                "deepVerified": true,
            ])
        case .text:
            print("Backfill examined \(result.examined) unembedded frame(s); embedded \(result.embedded).")
            print("Frames without vectors: \(result.remaining)")
            print("Embedding status: \(result.status)")
            print("Output: \(destinationURL.path)")
            print("Source unchanged: yes")
            print("Deep verification: PASS")
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
