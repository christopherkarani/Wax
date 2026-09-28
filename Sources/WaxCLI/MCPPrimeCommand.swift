import ArgumentParser
import Foundation
import Wax

enum MCPPrimeHost: String, CaseIterable, ExpressibleByArgument {
    case claude
    case codex
    case grok
    case cursor
    case opencode
    case openclaw
    case muse

    /// Thin adapter over the canonical host vocabulary.
    var registry: MCPHostRegistry.Host {
        switch self {
        case .claude: return .claude
        case .codex: return .codex
        case .grok: return .grok
        case .cursor: return .cursor
        case .opencode: return .opencode
        case .openclaw: return .openclaw
        case .muse: return .muse
        }
    }
}

enum MCPPrimeOutputFormat: String, CaseIterable, ExpressibleByArgument {
    case json
    case claude
    case codex
    case grok
    case cursor
    case muse

    var assemblyFormat: MCPPrimeAssembly.Format {
        MCPHostRegistry.primeFormat(hostName: rawValue)
    }
}

struct MCPPrimeOutcome: Sendable, Equatable {
    var exitCode: Int32
    var stdout: String
    var stderr: String
}

enum MCPPrimeRunner {
    static let defaultTimeoutSeconds: TimeInterval = 10

    struct Request: Sendable {
        var host: String
        var cwd: String
        var includePerson: Bool
        var format: MCPPrimeAssembly.Format
        var timeoutSeconds: TimeInterval
        var storePath: String
        var noEmbedder: Bool
        var embedderChoice: String
        var configuration: AgentBrokerConfiguration? = nil
        var probe: (@Sendable (AgentBrokerRequest, AgentBrokerConfiguration, TimeInterval) throws -> AgentBrokerResponse?)? = nil
    }

    static func run(_ request: Request) -> MCPPrimeOutcome {
        let attribution = MCPProjectAttributionResolver.resolve(
            explicitProject: nil,
            explicitRepo: nil,
            advertisedCWD: request.cwd,
            mcpRoots: []
        )
        func failureEnvelope(_ error: Error) -> MCPPrimeAssembly.Envelope {
            let message = sanitizeProbeError(error)
            return MCPPrimeAssembly.assemble(
                MCPPrimeAssembly.Input(
                    host: request.host,
                    includePerson: false,
                    projectMiss: !attribution.isResolved,
                    project: attribution.project,
                    repo: attribution.repo,
                    personCandidates: [],
                    projectCandidates: [],
                    handoff: nil,
                    probeFailed: true,
                    probeError: message,
                    probeReason: isTimeoutMessage(message) ? .timeout : .brokerDown
                )
            )
        }

        do {
            let configuration = try request.configuration ?? AgentBrokerCLI.configuration(
                storePath: request.storePath,
                embedderChoice: request.embedderChoice,
                noEmbedder: request.noEmbedder,
                requireVector: false,
                embedderTuning: .fromEnvironment()
            )
            let probe = request.probe ?? { req, config, timeout in
                try AgentBrokerClient.probe(
                    request: req,
                    configuration: config,
                    timeoutSeconds: timeout
                )
            }
            let envelope = try loadEnvelope(
                request: request,
                attribution: attribution,
                configuration: configuration,
                probe: probe
            )
            return MCPPrimeOutcome(
                exitCode: 0,
                stdout: MCPPrimeAssembly.render(envelope, format: request.format),
                stderr: stderrForFailedProbe(envelope)
            )
        } catch {
            // Hooks must never fail: exit 0 with the failure recorded in
            // the envelope (probe_failed/probe_error JSON, fixed model line).
            let envelope = failureEnvelope(error)
            return MCPPrimeOutcome(
                exitCode: 0,
                stdout: MCPPrimeAssembly.render(envelope, format: request.format),
                stderr: stderrForFailedProbe(envelope)
            )
        }
    }

    private static func loadEnvelope(
        request: Request,
        attribution: MCPProjectAttribution,
        configuration: AgentBrokerConfiguration,
        probe: @Sendable (AgentBrokerRequest, AgentBrokerConfiguration, TimeInterval) throws -> AgentBrokerResponse?
    ) throws -> MCPPrimeAssembly.Envelope {
        let deadline = Date().addingTimeInterval(max(0.05, request.timeoutSeconds))
        func remaining() -> TimeInterval {
            max(0.01, deadline.timeIntervalSinceNow)
        }

        var person: [MCPPrimeAssembly.Candidate] = []
        var project: [MCPPrimeAssembly.Candidate] = []
        var projectMiss = !attribution.isResolved
        var handoff: MCPPrimeAssembly.Handoff?
        var sawBroker = false
        // One failing probe must not abort the others: record the first
        // error and keep whatever partial results arrive.
        var probeError: String?
        var firstFailureKind: ProbeFailureKind?

        if attribution.isResolved, remaining() > 0.02 {
            let response = probeCatching(
                probe,
                AgentBrokerRequest(
                    command: "recall",
                    arguments: [
                        // Notes stay eligible via the types filter below but get no
                        // query keyword: assembly already ranks them last, and
                        // a keyword would bias broker-side top-8 scoring so
                        // notes could displace higher-signal hits.
                        "query": .string(
                            "\(attribution.project ?? attribution.repo ?? "project") lessons facts decisions constraints"
                        ),
                        "limit": .from(8),
                        "scope": .string("project"),
                        "cwd": .string(request.cwd),
                        "project": .from(attribution.project),
                        "repo": .from(attribution.repo),
                        "memory_types": .array([
                            .string(MemoryType.lesson.rawValue),
                            .string(MemoryType.fact.rawValue),
                            .string(MemoryType.decision.rawValue),
                            .string(MemoryType.constraint.rawValue),
                            .string(MemoryType.note.rawValue),
                        ]),
                        "mode": .string("text"),
                    ]
                ),
                configuration,
                remaining(),
                recordedError: &probeError,
                recordedKind: &firstFailureKind
            )
            if let payload = response?.payload {
                sawBroker = true
                let parsed = MCPPrimeAssembly.candidates(fromRecall: payload)
                project = parsed.items
                projectMiss = parsed.projectMiss || projectMiss
            }
        }

        if request.includePerson, remaining() > 0.02 {
            let response = probeCatching(
                probe,
                AgentBrokerRequest(
                    command: "recall",
                    arguments: [
                        "query": .string("standing preferences how this person works"),
                        "limit": .from(6),
                        "scope": .string("global"),
                        "memory_types": .array([.string(MemoryType.userPreference.rawValue)]),
                        "mode": .string("text"),
                    ]
                ),
                configuration,
                remaining(),
                recordedError: &probeError,
                recordedKind: &firstFailureKind
            )
            if let payload = response?.payload {
                sawBroker = true
                person = MCPPrimeAssembly.candidates(fromRecall: payload).items
            }
        }

        if attribution.isResolved, !projectMiss, remaining() > 0.02 {
            let response = probeCatching(
                probe,
                AgentBrokerRequest(
                    command: "handoff_latest",
                    arguments: ["project": .from(attribution.project)]
                ),
                configuration,
                remaining(),
                recordedError: &probeError,
                recordedKind: &firstFailureKind
            )
            if let payload = response?.payload {
                sawBroker = true
                handoff = MCPPrimeAssembly.handoff(from: payload)
            }
        }

        if !sawBroker, !attribution.isResolved {
            projectMiss = true
        }

        return MCPPrimeAssembly.assemble(
            MCPPrimeAssembly.Input(
                host: request.host,
                includePerson: request.includePerson,
                projectMiss: projectMiss,
                project: attribution.project,
                repo: attribution.repo,
                personCandidates: person,
                projectCandidates: project,
                handoff: handoff,
                probeFailed: probeError != nil,
                probeError: probeError,
                probeReason: probeReason(
                    firstFailureKind: firstFailureKind,
                    probeFailed: probeError != nil,
                    projectMiss: projectMiss
                )
            )
        )
    }

    /// Coarse class of one probe attempt's failure. Timeouts are retryable;
    /// unreachable covers a missing/dead socket and connection errors; an
    /// answered error means the broker replied but refused the request.
    private enum ProbeFailureKind {
        case timeout
        case unreachable
        case answeredWithError
    }

    /// Minimum remaining budget worth spending on a timeout retry. Below
    /// this the retry would expire immediately, so the first failure stands.
    private static let retryMinimumRemainingSeconds: TimeInterval = 0.5

    /// One probe call that never throws: failures record the first sanitized
    /// error and yield nil so sibling probes still run. A nil response means
    /// the broker never answered (missing/dead socket, timeout) — that is a
    /// failure, not an empty result: empty results arrive as successful
    /// responses with empty result lists. A cold broker gets one retry when
    /// the first attempt times out; any other failure stands immediately.
    private static func probeCatching(
        _ probe: @Sendable (AgentBrokerRequest, AgentBrokerConfiguration, TimeInterval) throws -> AgentBrokerResponse?,
        _ request: AgentBrokerRequest,
        _ configuration: AgentBrokerConfiguration,
        _ timeout: @autoclosure () -> TimeInterval,
        recordedError: inout String?,
        recordedKind: inout ProbeFailureKind?
    ) -> AgentBrokerResponse? {
        let first = attempt(probe, request, configuration, timeout())
        guard first.kind == .timeout, first.response == nil else {
            record(first, recordedError: &recordedError, recordedKind: &recordedKind)
            return first.response
        }
        guard timeout() > retryMinimumRemainingSeconds else {
            record(first, recordedError: &recordedError, recordedKind: &recordedKind)
            return nil
        }
        let second = attempt(probe, request, configuration, timeout())
        if second.response != nil {
            // Retry rescued a cold broker: record only if it answered badly.
            record(second, recordedError: &recordedError, recordedKind: &recordedKind)
            return second.response
        }
        // Both attempts failed: keep the first timeout's error.
        record(first, recordedError: &recordedError, recordedKind: &recordedKind)
        return nil
    }

    private static func attempt(
        _ probe: @Sendable (AgentBrokerRequest, AgentBrokerConfiguration, TimeInterval) throws -> AgentBrokerResponse?,
        _ request: AgentBrokerRequest,
        _ configuration: AgentBrokerConfiguration,
        _ timeout: TimeInterval
    ) -> (response: AgentBrokerResponse?, kind: ProbeFailureKind?, message: String?) {
        do {
            let response = try probe(request, configuration, timeout)
            if let response {
                if let message = response.error {
                    return (response, .answeredWithError, sanitizeProbeMessage(message))
                }
                return (response, nil, nil)
            }
            // A live socket that never answered is a timeout (cold broker);
            // no listener at all means the broker is down.
            if AgentBrokerClient.isSocketLive(socketPath: configuration.socketPath) {
                return (nil, .timeout, "broker probe timed out")
            }
            return (nil, .unreachable, "broker did not respond")
        } catch {
            let message = sanitizeProbeError(error)
            return (nil, isTimeoutMessage(message) ? .timeout : .unreachable, message)
        }
    }

    private static func record(
        _ failure: (response: AgentBrokerResponse?, kind: ProbeFailureKind?, message: String?),
        recordedError: inout String?,
        recordedKind: inout ProbeFailureKind?
    ) {
        guard let kind = failure.kind else { return }
        if recordedKind == nil {
            recordedKind = kind
        }
        if recordedError == nil, let message = failure.message {
            recordedError = message
        }
    }

    private static func probeReason(
        firstFailureKind: ProbeFailureKind?,
        probeFailed: Bool,
        projectMiss: Bool
    ) -> MCPPrimeAssembly.ProbeReason? {
        guard probeFailed else { return nil }
        switch firstFailureKind {
        case .timeout:
            return .timeout
        case .unreachable, .none:
            return .brokerDown
        case .answeredWithError:
            // The broker answered but the project lane is unusable.
            return projectMiss ? .projectMiss : .brokerDown
        }
    }

    private static func isTimeoutMessage(_ message: String) -> Bool {
        let lowered = message.lowercased()
        return lowered.contains("timed out") || lowered.contains("timeout")
    }

    /// Host JSON formats drop probe_error, so the failure must also travel on
    /// stderr for operators. The hook entrypoint stays silent by mapping this
    /// back to ""; only the standalone prime command writes it.
    private static func stderrForFailedProbe(_ envelope: MCPPrimeAssembly.Envelope) -> String {
        guard envelope.probeFailed else { return "" }
        return envelope.probeError ?? ""
    }

    private static func sanitizeProbeError(_ error: Error) -> String {
        sanitizeProbeMessage(String(describing: error))
    }

    private static func sanitizeProbeMessage(_ message: String) -> String {
        let cleaned = MCPPrimeAssembly.sanitize(message)
            .replacingOccurrences(of: "\n", with: " ")
        let prefix = String(cleaned.prefix(200))
        return prefix.isEmpty ? "unknown probe error" : prefix
    }
}

extension WaxCLI.MCP {
    struct Prime: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "prime",
            abstract: "Read-only host prime of bounded project memory. Never opens a session."
        )

        @Option(name: .customLong("host"), help: "Host namespace: claude, codex, grok, cursor, opencode, openclaw, muse")
        var host: MCPPrimeHost

        @Option(name: .customLong("cwd"), help: "Client working directory used to resolve project/repo")
        var cwd: String

        @Flag(name: .customLong("include-person"), help: "Include up to 3 global user_preference hits")
        var includePerson = false

        @Option(name: .customLong("format"), help: "Output format: json, claude, codex, grok, cursor, muse")
        var format: MCPPrimeOutputFormat = .json

        @Option(name: .customLong("timeout-secs"), help: "Probe deadline in seconds (default 10)")
        var timeoutSeconds: Double = MCPPrimeRunner.defaultTimeoutSeconds

        @Option(name: .customLong("store-path"), help: "Path to Wax memory store")
        var storePath: String = StoreSession.defaultStorePath

        @Flag(name: .customLong("no-embedder"), help: "Match a text-only broker socket")
        var noEmbedder = false

        @Option(name: .customLong("embedder"), help: "Embedder identity used to locate the broker socket")
        var embedder: String = EmbedderChoice.minilm.rawValue

        func run() throws {
            let outcome = MCPPrimeRunner.run(
                MCPPrimeRunner.Request(
                    host: host.rawValue,
                    cwd: cwd,
                    includePerson: includePerson,
                    format: format.assemblyFormat,
                    timeoutSeconds: timeoutSeconds,
                    storePath: storePath,
                    noEmbedder: noEmbedder,
                    embedderChoice: embedder
                )
            )
            FileHandle.standardOutput.write(Data((outcome.stdout + "\n").utf8))
            if !outcome.stderr.isEmpty {
                FileHandle.standardError.write(Data((outcome.stderr + "\n").utf8))
            }
        }
    }
}
