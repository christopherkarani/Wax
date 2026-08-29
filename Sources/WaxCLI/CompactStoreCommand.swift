import ArgumentParser
import Foundation
import Wax
import WaxCore

struct CompactStoreCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "compact-store",
        abstract: "Rewrite a copy of a Wax store with automatic WAL sizing"
    )

    @Option(
        name: .customLong("store-path"),
        help: "Source store path. Required; never defaults to ~/.wax/memory.wax."
    )
    var storePath: String

    @Option(name: .customLong("output"), help: "Destination store path")
    var output: String

    @Flag(
        name: .customLong("direct-store"),
        help: "Required. Open the source store file directly; never talks to the broker."
    )
    var directStore: Bool = false

    @Flag(
        name: .customLong("no-embedder"),
        help: "Disable MiniLM. Compact does not need an embedder."
    )
    var noEmbedder: Bool = false

    @Flag(name: .customLong("overwrite"), help: "Replace an existing destination file")
    var overwrite: Bool = false

    @Option(name: .customLong("format"), help: "Output format: json or text")
    var format: OutputFormat = .text

    func validate() throws {
        guard directStore else {
            throw ValidationError("--direct-store is required for compact-store")
        }
        try CompactStorePathPolicy.validate(
            storePath: storePath,
            output: output
        )
    }

    func runAsync() async throws {
        _ = noEmbedder
        let sourceURL = try StoreSession.resolveURL(storePath)
        let destinationURL = try CompactStorePathPolicy.destinationURL(from: output)
        try CompactStorePathPolicy.validate(
            storePath: storePath,
            output: output
        )
        try StoreRepairSupport.validate(
            source: sourceURL,
            destination: destinationURL,
            command: "compact-store"
        )
        try StoreRepairSupport.ensureRegularFileIfPresent(
            at: destinationURL,
            label: "output",
            command: "compact-store"
        )
        if FileManager.default.fileExists(atPath: destinationURL.path) {
            guard overwrite else {
                throw CLIError("output destination already exists; pass --overwrite to replace it")
            }
            try StoreRepairSupport.ensureDestinationUnlockedIfPresent(
                at: destinationURL,
                command: "compact-store"
            )
        }
        try failFastIfStoreHeld(at: sourceURL)

        let sourceIdentity = StoreRepairSupport.identity(of: sourceURL)
        let sourceCopyURL = StoreRepairSupport.stagingURL(for: destinationURL)
        let stagingURL = StoreRepairSupport.stagingURL(for: destinationURL)
        defer {
            try? FileManager.default.removeItem(at: sourceCopyURL)
            try? FileManager.default.removeItem(at: stagingURL)
        }
        let sourceFingerprint = try StoreRepairSupport.copySource(
            from: sourceURL,
            to: sourceCopyURL,
            overwrite: false
        )
        _ = try await StoreRepairSupport.verifyDeep(at: sourceCopyURL)

        let report = try await StoreSession.withOpen(at: sourceCopyURL, noEmbedder: true) { memory in
            try await memory.rewriteLiveSet(
                to: stagingURL,
                options: LiveSetRewriteOptions(
                    overwriteDestination: false,
                    dropNonLivePayloads: true,
                    verifyDeep: true
                )
            )
        }

        _ = try await StoreRepairSupport.verifyDeep(at: stagingURL)
        let sourceAfter = try StoreRepairSupport.fingerprint(of: sourceURL)
        guard sourceAfter == sourceFingerprint,
              StoreRepairSupport.identity(of: sourceURL) == sourceIdentity else {
            throw CLIError("source store changed during compaction; output is not promoted")
        }
        try StoreRepairSupport.validate(
            source: sourceURL,
            destination: destinationURL,
            command: "compact-store"
        )
        let promotion = try StoreRepairSupport.promoteVerifiedOutput(
            from: stagingURL,
            to: destinationURL,
            overwrite: overwrite
        )
        let publishedWal: WaxWALStats
        do {
            publishedWal = try await StoreRepairSupport.verifyDeep(at: destinationURL)
            try StoreRepairSupport.finalizePromotion(promotion)
        } catch {
            try? StoreRepairSupport.rollbackPromotion(promotion)
            throw error
        }

        switch format {
        case .json:
            printJSON([
                "sourcePath": sourceURL.path,
                "outputPath": destinationURL.path,
                "frameCount": report.frameCount,
                "activeFrameCount": report.activeFrameCount,
                "droppedPayloadFrames": report.droppedPayloadFrames,
                "logicalBytesBefore": report.logicalBytesBefore,
                "logicalBytesAfter": report.logicalBytesAfter,
                "walSizeAfter": publishedWal.walSize,
                "sourceUnchanged": true,
                "deepVerified": true,
            ])
        case .text:
            print("Compacted \(sourceURL.path) → \(destinationURL.path)")
            print("Frames: \(report.frameCount) (\(report.activeFrameCount) active)")
            print("Logical size: \(report.logicalBytesAfter) bytes (was \(report.logicalBytesBefore))")
            print("WAL size: \(publishedWal.walSize)")
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
