import ArgumentParser
import Foundation
import Wax

struct MCPCheckpointOutcome: Sendable, Equatable {
    var exitCode: Int32
    var stdout: String
    var stderr: String
}

enum MCPCheckpointRunner {
    static let defaultTimeoutSeconds: TimeInterval = 1.5
    static let defaultHandoffContent = "checkpoint"

    struct Request: Sendable {
        var sessionID: String?
        var host: String?
        var conversationID: String?
        var cwd: String?
        var contentFile: String?
        var strict: Bool
        var timeoutSeconds: TimeInterval
        var storePath: String
        var noEmbedder: Bool
        var embedderChoice: String
        var configuration: AgentBrokerConfiguration? = nil
        var probe: (@Sendable (AgentBrokerRequest, AgentBrokerConfiguration, TimeInterval) throws -> AgentBrokerResponse?)? = nil
        var sessionRootURL: URL? = nil
    }

    private enum Identity {
        case none
        case unique(BrokerSessionManifest)
        case ambiguous(Int)
    }

    static func run(_ request: Request) -> MCPCheckpointOutcome {
        do {
            return try execute(request)
        } catch {
            return finish(
                status: request.strict ? "rejected" : "skipped",
                reason: "broker_unavailable",
                alreadyEnded: false,
                strict: request.strict,
                extra: ["lease_seconds": VirtualSessionStore.defaultSessionLeaseSeconds]
            )
        }
    }

    private static func execute(_ request: Request) throws -> MCPCheckpointOutcome {
        let configuration = try request.configuration ?? AgentBrokerCLI.configuration(
            storePath: request.storePath,
            embedderChoice: request.embedderChoice,
            noEmbedder: request.noEmbedder,
            requireVector: false,
            embedderTuning: .fromEnvironment()
        )
        let sessionRoot = request.sessionRootURL
            ?? URL(fileURLWithPath: configuration.sessionRootPath, isDirectory: true)
        let probe = request.probe ?? { req, config, timeout in
            try AgentBrokerClient.probe(
                request: req,
                configuration: config,
                timeoutSeconds: timeout
            )
        }

        let content: String
        if let contentFile = request.contentFile {
            do {
                content = try readHandoff(from: contentFile)
            } catch {
                return finish(
                    status: request.strict ? "rejected" : "skipped",
                    reason: "content_unreadable",
                    alreadyEnded: false,
                    strict: request.strict
                )
            }
        } else {
            content = defaultHandoffContent
        }

        if let rawID = request.sessionID?.trimmingCharacters(in: .whitespacesAndNewlines), !rawID.isEmpty {
            guard let sessionID = UUID(uuidString: rawID) else {
                return finish(
                    status: request.strict ? "rejected" : "skipped",
                    reason: "invalid_session_id",
                    alreadyEnded: false,
                    strict: request.strict
                )
            }
            return try closeExact(
                sessionID: sessionID,
                content: content,
                request: request,
                configuration: configuration,
                sessionRoot: sessionRoot,
                probe: probe
            )
        }

        let host = request.host?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let conversationID = request.conversationID?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let cwd = request.cwd?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if host.isEmpty || conversationID.isEmpty {
            return finish(
                status: request.strict ? "rejected" : "skipped",
                reason: "no_bound_session",
                alreadyEnded: false,
                strict: request.strict
            )
        }

        let attribution = MCPProjectAttributionResolver.resolve(
            explicitProject: nil,
            explicitRepo: nil,
            advertisedCWD: cwd.isEmpty ? nil : cwd,
            mcpRoots: []
        )
        let key = HostConversationKey(
            hostNamespace: host,
            conversationID: conversationID,
            repoIdentity: attribution.repo ?? attribution.project ?? ""
        )
        let identity = try matchHostSession(
            wireConversationID: key.wireConversationID,
            project: attribution.project,
            repo: attribution.repo,
            rootURL: sessionRoot
        )
        switch identity {
        case .none:
            return finish(
                status: request.strict ? "rejected" : "skipped",
                reason: "no_bound_session",
                alreadyEnded: false,
                strict: request.strict
            )
        case .ambiguous:
            return finish(
                status: request.strict ? "rejected" : "skipped",
                reason: "ambiguous_identity",
                alreadyEnded: false,
                strict: request.strict
            )
        case .unique(let manifest):
            let facts = SessionOpenDecision.Facts(
                conversationID: key.wireConversationID,
                conversationMatch: SessionOpenDecision.Match(
                    sessionID: manifest.sessionID,
                    runID: manifest.runID
                ),
                hintedSessionID: nil,
                hintedResumable: false,
                priorUnique: nil,
                requestedRunID: nil
            )
            switch SessionOpenDecision.evaluate(facts) {
            case .startNew:
                return finish(
                    status: request.strict ? "rejected" : "skipped",
                    reason: "no_bound_session",
                    alreadyEnded: false,
                    strict: request.strict
                )
            case .resume(let sessionID):
                if manifest.status == .ended {
                    return finish(
                        status: "ok",
                        reason: "already_ended",
                        alreadyEnded: true,
                        strict: false
                    )
                }
                return try closeExact(
                    sessionID: sessionID,
                    content: content,
                    request: request,
                    configuration: configuration,
                    sessionRoot: sessionRoot,
                    probe: probe
                )
            }
        }
    }

    private static func matchHostSession(
        wireConversationID: String,
        project: String?,
        repo: String?,
        rootURL: URL
    ) throws -> Identity {
        let manifests = try BrokerSessionPersistence.listManifests(rootURL: rootURL)
        let matching = manifests.filter { manifest in
            guard manifest.conversationID == wireConversationID else { return false }
            if let project, manifest.project != project { return false }
            if let repo, manifest.repo != repo { return false }
            return true
        }
        let active = matching.filter { $0.status == .active }
        if active.count > 1 {
            return .ambiguous(active.count)
        }
        if active.count == 1 {
            let confirmed = try BrokerSessionPersistence.findActive(
                conversationID: wireConversationID,
                project: project,
                repo: repo,
                rootURL: rootURL
            )
            return .unique(confirmed ?? active[0])
        }
        if let ended = try BrokerSessionPersistence.findConversation(
            conversationID: wireConversationID,
            project: project,
            repo: repo,
            rootURL: rootURL
        ) {
            return .unique(ended)
        }
        return .none
    }

    private static func closeExact(
        sessionID: UUID,
        content: String,
        request: Request,
        configuration: AgentBrokerConfiguration,
        sessionRoot: URL,
        probe: @Sendable (AgentBrokerRequest, AgentBrokerConfiguration, TimeInterval) throws -> AgentBrokerResponse?
    ) throws -> MCPCheckpointOutcome {
        if let persisted = try? BrokerSessionPersistence.loadManifest(
            rootURL: sessionRoot,
            sessionID: sessionID
        ), persisted.status == .ended {
            return finish(
                status: "ok",
                reason: "already_ended",
                alreadyEnded: true,
                strict: false,
                extra: request.sessionID == nil ? [:] : ["session_id": sessionID.uuidString]
            )
        }

        let response = try probe(
            AgentBrokerRequest(
                command: "session_close",
                arguments: [
                    "session_id": .string(sessionID.uuidString),
                    "content": .string(content),
                ]
            ),
            configuration,
            max(0.05, request.timeoutSeconds)
        )
        guard let response else {
            return finish(
                status: request.strict ? "rejected" : "skipped",
                reason: "broker_unavailable",
                alreadyEnded: false,
                strict: request.strict,
                extra: [
                    "lease_seconds": VirtualSessionStore.defaultSessionLeaseSeconds,
                ]
            )
        }

        switch response.outcome {
        case .success(let payload):
            let alreadyEnded = payload.objectValue?["already_ended"]?.boolValue == true
            return finish(
                status: "ok",
                reason: alreadyEnded ? "already_ended" : "closed",
                alreadyEnded: alreadyEnded,
                strict: false,
                extra: request.sessionID == nil ? [:] : ["session_id": sessionID.uuidString]
            )
        case .failure(let payload, _):
            let code = payload?.objectValue?["code"]?.stringValue ?? ""
            if ["session_ended", "session_unknown", "session_not_live"].contains(code) {
                return finish(
                    status: "ok",
                    reason: "already_ended",
                    alreadyEnded: true,
                    strict: false
                )
            }
            return finish(
                status: request.strict ? "rejected" : "skipped",
                reason: "close_failed",
                alreadyEnded: false,
                strict: request.strict
            )
        }
    }

    private static func readHandoff(from path: String) throws -> String {
        let expanded = Pathing.expandPath(path)
        let handle = try FileHandle(forReadingFrom: URL(fileURLWithPath: expanded))
        defer { try? handle.close() }
        let data = (try handle.read(upToCount: BrokerLimits.maxSessionOpenHandoffContentBytes)) ?? Data()
        let text = String(decoding: data, as: UTF8.self)
        return SessionOpenAssembly.utf8Prefix(
            text,
            maxBytes: BrokerLimits.maxSessionOpenHandoffContentBytes
        )
    }

    private static func finish(
        status: String,
        reason: String,
        alreadyEnded: Bool,
        strict: Bool,
        extra: [String: Any] = [:]
    ) -> MCPCheckpointOutcome {
        var object: [String: Any] = [
            "status": status,
            "reason": reason,
            "already_ended": alreadyEnded,
        ]
        for (key, value) in extra {
            object[key] = value
        }
        let data = (try? JSONSerialization.data(
            withJSONObject: object,
            options: [.sortedKeys, .withoutEscapingSlashes]
        )) ?? Data("{}".utf8)
        let stdout = String(data: data, encoding: .utf8) ?? "{}"
        let exitCode: Int32 = (strict && status != "ok") ? 1 : 0
        return MCPCheckpointOutcome(exitCode: exitCode, stdout: stdout, stderr: "")
    }
}

extension WaxCLI.MCP {
    struct Checkpoint: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "checkpoint",
            abstract: "Close an exact Wax session or a namespaced host conversation. Never opens."
        )

        @Option(name: .customLong("session-id"), help: "Broker-issued session UUID")
        var sessionID: String?

        @Option(name: .customLong("content-file"), help: "Bounded handoff file. Not a transcript ingest.")
        var contentFile: String?

        @Option(name: .customLong("host"), help: "Host namespace for host-key resolve")
        var host: MCPPrimeHost?

        @Option(name: .customLong("conversation-id"), help: "Stable host conversation id")
        var conversationID: String?

        @Option(name: .customLong("cwd"), help: "Scopes host-key lookup; cannot select a session by itself")
        var cwd: String?

        @Flag(name: .customLong("strict"), help: "Exit nonzero on skip/reject")
        var strict = false

        @Option(name: .customLong("timeout-secs"), help: "Probe deadline in seconds (default 1.5)")
        var timeoutSeconds: Double = MCPCheckpointRunner.defaultTimeoutSeconds

        @Option(name: .customLong("store-path"), help: "Path to Wax memory store")
        var storePath: String = StoreSession.defaultStorePath

        @Flag(name: .customLong("no-embedder"), help: "Match a text-only broker socket")
        var noEmbedder = false

        @Option(name: .customLong("embedder"), help: "Embedder identity used to locate the broker socket")
        var embedder: String = EmbedderChoice.minilm.rawValue

        func run() throws {
            let outcome = MCPCheckpointRunner.run(
                MCPCheckpointRunner.Request(
                    sessionID: sessionID,
                    host: host?.rawValue,
                    conversationID: conversationID,
                    cwd: cwd,
                    contentFile: contentFile,
                    strict: strict,
                    timeoutSeconds: timeoutSeconds,
                    storePath: storePath,
                    noEmbedder: noEmbedder,
                    embedderChoice: embedder
                )
            )
            FileHandle.standardOutput.write(Data((outcome.stdout + "\n").utf8))
            if outcome.exitCode != 0 {
                throw ExitCode(outcome.exitCode)
            }
        }
    }
}
