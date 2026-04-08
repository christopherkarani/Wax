import ArgumentParser
import Foundation
import Wax

struct HandoffCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "handoff",
        abstract: "Store a handoff note for cross-session continuity"
    )

    @OptionGroup var store: VectorStoreOptions

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

        if AgentBrokerPolicy.shouldUseBroker(store: store) {
            let response = try await AgentBrokerCLI.perform(
                command: "handoff",
                arguments: [
                    "content": .string(trimmed),
                    "project": .from(project),
                    "pending_tasks": .array(task.map(AgentBrokerValue.string)),
                ],
                storePath: store.storePath,
                embedderChoice: store.embedder.rawValue,
                noEmbedder: store.noEmbedder,
                requireVector: store.requireVector,
                embedderTuning: store.embedderTuning
            )
            let payload = try brokerPayloadObject(response)
            let frameID = brokerInt64(payload, "frame_id") ?? 0
            switch store.format {
            case .json:
                printJSON([
                    "status": "ok",
                    "frame_id": frameID,
                ])
            case .text:
                print("Handoff stored (frame \(frameID)).")
            }
            return
        }

        let url = try StoreSession.resolveURL(store.storePath)
        // Store text-only for fast CLI response; embeddings index on next recall/search.
        try await StoreSession.withOpen(at: url, noEmbedder: true) { memory in
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
}

struct HandoffLatestCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "handoff-latest",
        abstract: "Retrieve the most recent handoff note"
    )

    @OptionGroup var store: VectorStoreOptions

    @Option(name: .customLong("project"), help: "Filter by project name")
    var project: String?

    func runAsync() async throws {
        if AgentBrokerPolicy.shouldUseBroker(store: store) {
            let response = try await AgentBrokerCLI.perform(
                command: "handoff_latest",
                arguments: [
                    "project": .from(project),
                ],
                storePath: store.storePath,
                embedderChoice: store.embedder.rawValue,
                noEmbedder: store.noEmbedder,
                requireVector: store.requireVector,
                embedderTuning: store.embedderTuning
            )
            let payload = try brokerPayloadObject(response)
            let found = brokerBool(payload, "found") ?? false
            guard found else {
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
                    "frame_id": brokerInt64(payload, "frame_id") ?? 0,
                    "timestamp_ms": brokerInt64(payload, "timestamp_ms") ?? 0,
                    "project": brokerString(payload, "project") as Any,
                    "pending_tasks": brokerArray(payload, "pending_tasks").compactMap(\.stringValue),
                    "content": brokerString(payload, "content") ?? "",
                ])
            case .text:
                if let proj = brokerString(payload, "project") {
                    print("Project: \(proj)")
                }
                let pending = brokerArray(payload, "pending_tasks").compactMap(\.stringValue)
                if !pending.isEmpty {
                    print("Pending tasks:")
                    for task in pending {
                        print("  - \(task)")
                    }
                }
                print(brokerString(payload, "content") ?? "")
            }
            return
        }

        let url = try StoreSession.resolveURL(store.storePath)
        // Read-only operation: skip embedder to avoid unnecessary MiniLM loading.
        try await StoreSession.withOpen(at: url, noEmbedder: true) { memory in
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
}
