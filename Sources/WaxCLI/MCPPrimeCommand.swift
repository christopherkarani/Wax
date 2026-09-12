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
}

enum MCPPrimeOutputFormat: String, CaseIterable, ExpressibleByArgument {
    case json
    case claude
    case codex
    case grok
    case cursor

    var assemblyFormat: MCPPrimeAssembly.Format {
        MCPPrimeAssembly.Format(rawValue: rawValue) ?? .json
    }
}

struct MCPPrimeOutcome: Sendable, Equatable {
    var exitCode: Int32
    var stdout: String
    var stderr: String
}

enum MCPPrimeRunner {
    static let defaultTimeoutSeconds: TimeInterval = 1.5

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
        let empty = MCPPrimeAssembly.assemble(
            MCPPrimeAssembly.Input(
                host: request.host,
                includePerson: false,
                projectMiss: !attribution.isResolved,
                project: attribution.project,
                repo: attribution.repo,
                personCandidates: [],
                projectCandidates: [],
                handoff: nil
            )
        )
        let renderedEmpty = MCPPrimeAssembly.render(empty, format: request.format)

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
                stderr: ""
            )
        } catch {
            return MCPPrimeOutcome(exitCode: 0, stdout: renderedEmpty, stderr: "")
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

        if attribution.isResolved, remaining() > 0.02 {
            let response = try probe(
                AgentBrokerRequest(
                    command: "recall",
                    arguments: [
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
                        ]),
                        "mode": .string("text"),
                    ]
                ),
                configuration,
                remaining()
            )
            if let payload = response?.payload {
                sawBroker = true
                let parsed = MCPPrimeAssembly.candidates(fromRecall: payload)
                project = parsed.items
                projectMiss = parsed.projectMiss || projectMiss
            }
        }

        if request.includePerson, remaining() > 0.02 {
            let response = try probe(
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
                remaining()
            )
            if let payload = response?.payload {
                sawBroker = true
                person = MCPPrimeAssembly.candidates(fromRecall: payload).items
            }
        }

        if attribution.isResolved, !projectMiss, remaining() > 0.02 {
            let response = try probe(
                AgentBrokerRequest(
                    command: "handoff_latest",
                    arguments: ["project": .from(attribution.project)]
                ),
                configuration,
                remaining()
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
                handoff: handoff
            )
        )
    }
}

extension WaxCLI.MCP {
    struct Prime: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "prime",
            abstract: "Read-only host prime of bounded project memory. Never opens a session."
        )

        @Option(name: .customLong("host"), help: "Host namespace: claude, codex, grok, cursor, opencode, openclaw")
        var host: MCPPrimeHost

        @Option(name: .customLong("cwd"), help: "Client working directory used to resolve project/repo")
        var cwd: String

        @Flag(name: .customLong("include-person"), help: "Include up to 3 global user_preference hits")
        var includePerson = false

        @Option(name: .customLong("format"), help: "Output format: json, claude, codex, grok, cursor")
        var format: MCPPrimeOutputFormat = .json

        @Option(name: .customLong("timeout-secs"), help: "Probe deadline in seconds (default 1.5)")
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
        }
    }
}
