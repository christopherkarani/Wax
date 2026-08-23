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

        if AgentBrokerPolicy.shouldUseBroker(store: store) {
            let configuration = try AgentBrokerCLI.configuration(
                storePath: store.storePath,
                embedderChoice: store.embedder.rawValue,
                noEmbedder: store.noEmbedder,
                requireVector: store.requireVector,
                embedderTuning: store.embedderTuning
            )
            let result = try await AgentBrokerClient.performRemember(
                content: trimmed,
                metadata: meta,
                configuration: configuration
            )
            render(format: store.format, result: result)
            return
        }

        let url = try StoreSession.resolveURL(store.storePath)
        // Respect `--no-embedder`; for write-heavy usage we skip prewarm to reduce cold-start latency.
        try await StoreSession.withOpen(
            at: url,
            noEmbedder: store.noEmbedder,
            skipPrewarm: true,
            embedderChoice: store.embedder,
            embedderTuning: store.embedderTuning,
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

            render(
                format: store.format,
                result: BrokerRememberResult(
                    framesAdded: Int(added),
                    frameCount: Int(after.frameCount),
                    pendingFrames: Int(after.pendingFrames)
                )
            )
        }
    }

    private func render(format: OutputFormat, result: BrokerRememberResult) {
        switch format {
        case .json:
            printJSON([
                "status": "ok",
                "framesAdded": result.framesAdded,
                "frameCount": result.frameCount,
                "pendingFrames": result.pendingFrames,
            ])
        case .text:
            print("Remembered. \(result.framesAdded) frame(s) added (\(result.frameCount) total, \(result.pendingFrames) pending).")
        }
    }
}
