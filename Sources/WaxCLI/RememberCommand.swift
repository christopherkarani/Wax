import ArgumentParser
import Foundation
import Wax

struct RememberCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "remember",
        abstract: "Store content in Wax memory"
    )

    @OptionGroup var store: StoreOptions

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
        let url = try StoreSession.resolveURL(store.storePath)
        let memory = try await StoreSession.open(at: url, noEmbedder: store.noEmbedder)
        defer { Task { try? await memory.close() } }

        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw CLIError("Content must not be empty")
        }

        var meta: [String: String] = [:]
        for (key, value) in metadata {
            meta[key] = value
        }

        let before = await memory.runtimeStats()
        try await memory.remember(trimmed, metadata: meta)

        // CLI is single-shot: auto-flush so frames are immediately searchable.
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
