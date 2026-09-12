import Foundation
import Wax

struct HostHookStdinEvent: Equatable, Sendable {
    var eventName: String
    var conversationID: String
    var cwd: String
}

enum HostHookStdinParser {
    static let neverCloseEventNames: Set<String> = [
        "stop",
        "session.idle",
        "session.compacted",
        "experimental.session.compacting",
        "session.status",
    ]

    static func parse(_ data: Data) -> HostHookStdinEvent {
        let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        let eventName = firstString(
            in: object,
            keys: ["hook_event_name", "hookEventName", "event_name", "event"]
        )
        let conversationID = firstString(
            in: object,
            keys: ["session_id", "sessionId", "conversation_id", "conversationId"]
        )
        let cwd = firstString(in: object, keys: ["cwd", "workspace_root", "workspaceRoot"])
        return HostHookStdinEvent(
            eventName: eventName,
            conversationID: conversationID,
            cwd: cwd
        )
    }

    static func isNeverClose(_ eventName: String) -> Bool {
        neverCloseEventNames.contains(eventName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
    }

    private static func firstString(in object: [String: Any]?, keys: [String]) -> String {
        guard let object else { return "" }
        for key in keys {
            if let value = object[key] as? String {
                let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    return trimmed
                }
            }
        }
        return ""
    }
}

enum MCPRunHookRunner {
    struct Outcome: Sendable, Equatable {
        var exitCode: Int32
        var stdout: String
        var stderr: String
    }

    static func run(
        host: String,
        role: String,
        stdin: Data,
        storePath: String = StoreSession.defaultStorePath,
        noEmbedder: Bool = false,
        embedderChoice: String = EmbedderChoice.minilm.rawValue
    ) -> Outcome {
        let event = HostHookStdinParser.parse(stdin)
        let normalizedRole = role.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        switch normalizedRole {
        case "prime":
            return prime(
                host: host,
                event: event,
                storePath: storePath,
                noEmbedder: noEmbedder,
                embedderChoice: embedderChoice
            )
        case "checkpoint":
            return checkpoint(
                host: host,
                event: event,
                storePath: storePath,
                noEmbedder: noEmbedder,
                embedderChoice: embedderChoice
            )
        default:
            return Outcome(exitCode: 0, stdout: "", stderr: "")
        }
    }

    private static func prime(
        host: String,
        event: HostHookStdinEvent,
        storePath: String,
        noEmbedder: Bool,
        embedderChoice: String
    ) -> Outcome {
        let format = MCPPrimeAssembly.Format(rawValue: host) ?? .json
        let outcome = MCPPrimeRunner.run(
            MCPPrimeRunner.Request(
                host: host,
                conversationID: event.conversationID,
                cwd: event.cwd,
                includePerson: false,
                format: format,
                timeoutSeconds: MCPPrimeRunner.defaultTimeoutSeconds,
                storePath: storePath,
                noEmbedder: noEmbedder,
                embedderChoice: embedderChoice
            )
        )
        return Outcome(exitCode: 0, stdout: outcome.stdout, stderr: "")
    }

    private static func checkpoint(
        host: String,
        event: HostHookStdinEvent,
        storePath: String,
        noEmbedder: Bool,
        embedderChoice: String
    ) -> Outcome {
        if HostHookStdinParser.isNeverClose(event.eventName) {
            return Outcome(exitCode: 0, stdout: "", stderr: "")
        }
        let outcome = MCPCheckpointRunner.run(
            MCPCheckpointRunner.Request(
                sessionID: nil,
                host: host,
                conversationID: event.conversationID.isEmpty ? nil : event.conversationID,
                cwd: event.cwd.isEmpty ? nil : event.cwd,
                contentFile: nil,
                strict: false,
                timeoutSeconds: MCPCheckpointRunner.defaultTimeoutSeconds,
                storePath: storePath,
                noEmbedder: noEmbedder,
                embedderChoice: embedderChoice
            )
        )
        return Outcome(exitCode: 0, stdout: outcome.stdout, stderr: "")
    }
}
