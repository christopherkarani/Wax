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
        let destURL = try CompactStorePathPolicy.destinationURL(from: output)
        try CompactStorePathPolicy.validate(
            storePath: storePath,
            output: output
        )
        try failFastIfStoreHeld(at: sourceURL)

        let report = try await StoreSession.withOpen(at: sourceURL, noEmbedder: true) { memory in
            try await memory.rewriteLiveSet(
                to: destURL,
                options: LiveSetRewriteOptions(
                    overwriteDestination: overwrite,
                    dropNonLivePayloads: true,
                    verifyDeep: true
                )
            )
        }

        let dest = try await Wax.open(at: destURL)
        let destWal = await dest.walStats()
        try await dest.close()

        switch format {
        case .json:
            printJSON([
                "sourcePath": report.sourceURL.path,
                "outputPath": report.destinationURL.path,
                "frameCount": report.frameCount,
                "activeFrameCount": report.activeFrameCount,
                "droppedPayloadFrames": report.droppedPayloadFrames,
                "logicalBytesBefore": report.logicalBytesBefore,
                "logicalBytesAfter": report.logicalBytesAfter,
                "walSizeAfter": destWal.walSize,
            ])
        case .text:
            print("Compacted \(report.sourceURL.path) → \(report.destinationURL.path)")
            print("Frames: \(report.frameCount) (\(report.activeFrameCount) active)")
            print("Logical size: \(report.logicalBytesAfter) bytes (was \(report.logicalBytesBefore))")
            print("WAL size: \(destWal.walSize)")
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

enum CompactStorePathPolicy {
    static func validate(storePath: String, output: String) throws {
        let source = expandedURL(storePath)
        let dest = expandedURL(output)
        try refuseLiveFamily(source, command: "compact-store")
        try refuseLiveFamily(dest, command: "compact-store")
        if source == dest {
            throw ValidationError("compact-store destination must differ from source")
        }
    }

    static func refuseLiveFamily(_ url: URL, command: String) throws {
        if url == liveFamilyURL() {
            throw ValidationError(
                "\(command) refuses the live family store path \(StoreSession.defaultStorePath)"
            )
        }
    }

    static func destinationURL(from raw: String) throws -> URL {
        let url = expandedURL(raw)
        let dir = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return url
    }

    static func liveFamilyURL() -> URL {
        expandedURL(StoreSession.defaultStorePath)
    }

    /// Trim then tilde-expand. Must match `StoreSession.resolveURL` identity without creating directories.
    static func expandedURL(_ raw: String) -> URL {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let expanded = (trimmed as NSString).expandingTildeInPath
        return URL(fileURLWithPath: expanded).standardizedFileURL
    }
}
