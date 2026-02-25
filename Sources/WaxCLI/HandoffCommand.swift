import ArgumentParser
import Foundation
import Wax

struct HandoffCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "handoff",
        abstract: "Store a handoff note for cross-session continuity"
    )

    @OptionGroup var store: StoreOptions

    @Argument(help: "Handoff content describing current state and context")
    var content: String

    @Option(name: .customLong("project"), help: "Project name to tag the handoff")
    var project: String?

    @Option(name: .customLong("task"), help: "Pending task (repeatable)")
    var task: [String] = []

    func runAsync() async throws {
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw CLIError("Content must not be empty")
        }

        let url = try StoreSession.resolveURL(store.storePath)
        let memory = try await StoreSession.open(at: url, noEmbedder: store.noEmbedder)
        defer { Task { try? await memory.close() } }

        let frameId = try await memory.rememberHandoff(
            content: trimmed,
            project: project,
            pendingTasks: task,
            sessionId: nil
        )

        // CLI is single-shot: auto-flush so the handoff is immediately retrievable.
        try await memory.flush()

        switch store.format {
        case .json:
            printJSON([
                "status": "ok",
                "frame_id": frameId,
            ])
        case .text:
            print("Handoff stored (frame \(frameId)).")
        }
    }
}

struct HandoffLatestCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "handoff-latest",
        abstract: "Retrieve the most recent handoff note"
    )

    @OptionGroup var store: StoreOptions

    @Option(name: .customLong("project"), help: "Filter by project name")
    var project: String?

    func runAsync() async throws {
        let url = try StoreSession.resolveURL(store.storePath)
        // Read-only operation: skip embedder to avoid unnecessary MiniLM loading.
        let memory = try await StoreSession.open(at: url, noEmbedder: true)
        defer { Task { try? await memory.close() } }

        guard let latest = try await memory.latestHandoff(project: project) else {
            switch store.format {
            case .json:
                printJSON(["found": false])
            case .text:
                print("No handoff found.")
            }
            return
        }

        switch store.format {
        case .json:
            printJSON([
                "found": true,
                "frame_id": latest.frameId,
                "timestamp_ms": latest.timestampMs,
                "project": latest.project ?? NSNull(),
                "pending_tasks": latest.pendingTasks,
                "content": latest.content,
            ])
        case .text:
            if let proj = latest.project {
                print("Project: \(proj)")
            }
            if !latest.pendingTasks.isEmpty {
                print("Pending tasks:")
                for task in latest.pendingTasks {
                    print("  - \(task)")
                }
            }
            print(latest.content)
        }
    }
}
