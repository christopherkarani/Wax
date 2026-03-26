import ArgumentParser
import Foundation
import Wax

struct RememberCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "remember",
        abstract: "Store content in Wax memory"
    )

    @OptionGroup var store: VectorStoreOptions

    @Argument(help: "Content to remember")
    var content: String

    @Option(
        name: .customLong("metadata"),
        help: "Metadata as key=value (repeatable)",
        transform: { raw in
            guard let eqIndex = raw.firstIndex(of: "=") else {
                throw ValidationError("Metadata must be in key=value format, got '\(raw)'")
            }
            let key = String(raw[raw.startIndex..<eqIndex])
            let value = String(raw[raw.index(after: eqIndex)...])
            guard !key.isEmpty else {
                throw ValidationError("Metadata key must not be empty")
            }
            return (key, value)
        }
    )
    var metadata: [(String, String)] = []

    func runAsync() async throws {
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw CLIError("Content must not be empty")
        }

        var meta: [String: String] = [:]
        for (key, value) in metadata {
            meta[key] = value
        }

        if AgentDaemonPolicy.shouldUseDaemonForRemember(store: store),
           let response = try AgentDaemonTransport.perform(
               request: CLIDaemonRequest(
                   id: nil,
                   command: "remember",
                   content: trimmed,
                   query: nil,
                   metadata: meta,
                   mode: nil,
                   topK: nil,
                   limit: nil
               ),
               storePath: store.storePath,
               embedderChoice: store.embedder
           ) {
            guard response.ok else {
                throw CLIError(response.error ?? "Daemon remember failed")
            }
            guard case .remember(let frameCount, let pendingFrames, let framesAdded)? = response.payload else {
                throw CLIError("Daemon remember returned an unexpected payload")
            }
            switch store.format {
            case .json:
                printJSON([
                    "status": "ok",
                    "framesAdded": framesAdded,
                    "frameCount": frameCount,
                    "pendingFrames": pendingFrames,
                ])
            case .text:
                print("Remembered. \(framesAdded) frame(s) added (\(frameCount) total, \(pendingFrames) pending).")
            }
            return
        }

        let url = try StoreSession.resolveURL(store.storePath)
        // Respect `--no-embedder`; for write-heavy usage we skip prewarm to reduce cold-start latency.
        try await StoreSession.withOpen(
            at: url,
            noEmbedder: store.noEmbedder,
            skipPrewarm: true,
            embedderChoice: store.embedder,
            requireVector: store.requireVector
        ) { memory in
            let before = await memory.runtimeStats()
            try await memory.remember(trimmed, metadata: meta)

            // CLI is single-shot: auto-flush so frames are immediately searchable via FTS.
            try await memory.flush()

            let after = await memory.runtimeStats()
            let totalBefore = before.frameCount + before.pendingFrames
            let totalAfter = after.frameCount + after.pendingFrames
            let added = totalAfter >= totalBefore ? (totalAfter - totalBefore) : 0

            switch store.format {
            case .json:
                printJSON([
                    "status": "ok",
                    "framesAdded": added,
                    "frameCount": after.frameCount,
                    "pendingFrames": after.pendingFrames,
                ])
            case .text:
                print("Remembered. \(added) frame(s) added (\(after.frameCount) total, \(after.pendingFrames) pending).")
            }
        }
    }
}
