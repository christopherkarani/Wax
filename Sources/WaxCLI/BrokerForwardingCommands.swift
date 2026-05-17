import ArgumentParser
import Foundation
import Wax

struct BrokerForwardOptions: ParsableArguments {
    @Option(name: .customLong("arg"), help: "Broker argument as key=value. Repeatable.")
    var arg: [String] = []

    @Option(name: .customLong("json-args"), help: "Additional broker arguments as a JSON object.")
    var jsonArgs: String?

    func values() throws -> [String: AgentBrokerValue] {
        var values: [String: AgentBrokerValue] = [:]
        if let jsonArgs {
            let data = Data(jsonArgs.utf8)
            let object = try JSONSerialization.jsonObject(with: data)
            guard let dict = object as? [String: Any] else {
                throw CLIError("--json-args must be a JSON object")
            }
            for (key, value) in dict {
                values[key] = try AgentBrokerValue(jsonObject: value)
            }
        }

        for raw in arg {
            guard let separator = raw.firstIndex(of: "=") else {
                throw CLIError("--arg must be in key=value format")
            }
            let key = String(raw[..<separator])
            let rawValue = String(raw[raw.index(after: separator)...])
            guard !key.isEmpty else {
                throw CLIError("--arg key must not be empty")
            }
            values[key] = AgentBrokerValue(scalarString: rawValue)
        }
        return values
    }
}

private extension AgentBrokerValue {
    init(scalarString raw: String) {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed == "null" {
            self = .null
        } else if trimmed == "true" {
            self = .bool(true)
        } else if trimmed == "false" {
            self = .bool(false)
        } else if let int = Int64(trimmed) {
            self = .int(int)
        } else if let double = Double(trimmed) {
            self = .double(double)
        } else {
            self = .string(raw)
        }
    }

    init(jsonObject: Any) throws {
        switch jsonObject {
        case _ as NSNull:
            self = .null
        case let value as Bool:
            self = .bool(value)
        case let value as Int:
            self = .int(Int64(value))
        case let value as Int64:
            self = .int(value)
        case let value as Double:
            self = value.rounded() == value ? .int(Int64(value)) : .double(value)
        case let value as String:
            self = .string(value)
        case let values as [Any]:
            self = .array(try values.map { try AgentBrokerValue(jsonObject: $0) })
        case let values as [String: Any]:
            self = .object(try values.mapValues { try AgentBrokerValue(jsonObject: $0) })
        default:
            throw CLIError("Unsupported JSON argument value: \(jsonObject)")
        }
    }
}

private func runBrokerForwardedCommand(
    _ command: String,
    store: VectorStoreOptions,
    forwarded: BrokerForwardOptions,
    baseArguments: [String: AgentBrokerValue] = [:],
    keepBrokerAlive: Bool = false
) async throws {
    guard !store.directStore else {
        throw CLIError("--direct-store is not supported for broker parity commands")
    }
    var arguments = try forwarded.values()
    for (key, value) in baseArguments {
        arguments[key] = value
    }
    let response = try await AgentBrokerCLI.perform(
        command: command,
        arguments: arguments,
        storePath: store.storePath,
        embedderChoice: store.embedder.rawValue,
        noEmbedder: store.noEmbedder,
        requireVector: store.requireVector,
        embedderTuning: store.embedderTuning,
        shutdownIfStarted: !keepBrokerAlive
    )
    printBrokerResponse(response, format: store.format)
}

private func printBrokerResponse(_ response: AgentBrokerResponse, format: OutputFormat) {
    let payload = response.payload ?? .object(["status": .string("ok")])
    switch format {
    case .json:
        printJSONObject(payload.toJSONObject(), pretty: true)
    case .text:
        if case .object(let object) = payload,
           let displayText = object["display_text"]?.stringValue ?? object["message"]?.stringValue {
            print(displayText)
        } else {
            printJSONObject(payload.toJSONObject(), pretty: false)
        }
    }
}

private func printJSONObject(_ object: Any, pretty: Bool) {
    let options: JSONSerialization.WritingOptions = pretty
        ? [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        : [.sortedKeys, .withoutEscapingSlashes]
    guard JSONSerialization.isValidJSONObject(object),
          let data = try? JSONSerialization.data(withJSONObject: object, options: options),
          let string = String(data: data, encoding: .utf8)
    else {
        print("\(object)")
        return
    }
    print(string)
}

struct MemoryAppendCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "memory-append", abstract: "Append memory through the broker-compatible surface")
    @OptionGroup var store: VectorStoreOptions
    @OptionGroup var forwarded: BrokerForwardOptions
    @Argument var content: String
    func runAsync() async throws {
        let values = try forwarded.values()
        try await runBrokerForwardedCommand(
            "memory_append",
            store: store,
            forwarded: forwarded,
            baseArguments: ["content": .string(content)],
            keepBrokerAlive: values["session_id"] != nil
        )
    }
}

struct MemorySearchCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "memory-search", abstract: "Search broker memory horizons")
    @OptionGroup var store: VectorStoreOptions
    @OptionGroup var forwarded: BrokerForwardOptions
    @Argument var query: String
    @Option(name: .customLong("top-k")) var topK: Int?
    func runAsync() async throws {
        let values = try forwarded.values()
        var args: [String: AgentBrokerValue] = ["query": .string(query)]
        if let topK { args["topK"] = .from(topK) }
        try await runBrokerForwardedCommand(
            "memory_search",
            store: store,
            forwarded: forwarded,
            baseArguments: args,
            keepBrokerAlive: values["session_id"] != nil
        )
    }
}

struct MemoryGetCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "memory-get", abstract: "Read a memory by stable memory_id")
    @OptionGroup var store: VectorStoreOptions
    @OptionGroup var forwarded: BrokerForwardOptions
    @Argument var memoryID: String
    func runAsync() async throws {
        try await runBrokerForwardedCommand("memory_get", store: store, forwarded: forwarded, baseArguments: ["memory_id": .string(memoryID)])
    }
}

struct MemoryPromoteCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "memory-promote", abstract: "Promote session memory into durable memory")
    @OptionGroup var store: VectorStoreOptions
    @OptionGroup var forwarded: BrokerForwardOptions
    func runAsync() async throws { try await runBrokerForwardedCommand("memory_promote", store: store, forwarded: forwarded) }
}

struct PromoteCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "promote", abstract: "Alias for memory-promote")
    @OptionGroup var store: VectorStoreOptions
    @OptionGroup var forwarded: BrokerForwardOptions
    func runAsync() async throws { try await runBrokerForwardedCommand("promote", store: store, forwarded: forwarded) }
}

struct MemoryHealthCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "memory-health", abstract: "Inspect memory quality and health")
    @OptionGroup var store: VectorStoreOptions
    @OptionGroup var forwarded: BrokerForwardOptions
    func runAsync() async throws { try await runBrokerForwardedCommand("memory_health", store: store, forwarded: forwarded) }
}

struct KnowledgeCaptureCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "knowledge-capture", abstract: "Capture durable knowledge and optional structured facts")
    @OptionGroup var store: VectorStoreOptions
    @OptionGroup var forwarded: BrokerForwardOptions
    @Argument var content: String
    func runAsync() async throws {
        try await runBrokerForwardedCommand("knowledge_capture", store: store, forwarded: forwarded, baseArguments: ["content": .string(content)])
    }
}

struct CorpusSearchCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "corpus-search", abstract: "Search broker-managed session history")
    @OptionGroup var store: VectorStoreOptions
    @OptionGroup var forwarded: BrokerForwardOptions
    @Argument var query: String
    func runAsync() async throws {
        try await runBrokerForwardedCommand("corpus_search", store: store, forwarded: forwarded, baseArguments: ["query": .string(query)])
    }
}

struct SessionStartCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "session-start", abstract: "Start a broker-managed session")
    @OptionGroup var store: VectorStoreOptions
    @OptionGroup var forwarded: BrokerForwardOptions
    func runAsync() async throws { try await runBrokerForwardedCommand("session_start", store: store, forwarded: forwarded, keepBrokerAlive: true) }
}

struct SessionResumeCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "session-resume", abstract: "Resume a broker-managed session")
    @OptionGroup var store: VectorStoreOptions
    @OptionGroup var forwarded: BrokerForwardOptions
    func runAsync() async throws { try await runBrokerForwardedCommand("session_resume", store: store, forwarded: forwarded, keepBrokerAlive: true) }
}

struct SessionEndCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "session-end", abstract: "End a broker-managed session")
    @OptionGroup var store: VectorStoreOptions
    @OptionGroup var forwarded: BrokerForwardOptions
    func runAsync() async throws { try await runBrokerForwardedCommand("session_end", store: store, forwarded: forwarded, keepBrokerAlive: false) }
}

struct SessionSynthesizeCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "session-synthesize", abstract: "Summarize and promote session memory candidates")
    @OptionGroup var store: VectorStoreOptions
    @OptionGroup var forwarded: BrokerForwardOptions
    func runAsync() async throws { try await runBrokerForwardedCommand("session_synthesize", store: store, forwarded: forwarded, keepBrokerAlive: true) }
}

struct CompactContextCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "compact-context", abstract: "Build a token-budgeted memory context")
    @OptionGroup var store: VectorStoreOptions
    @OptionGroup var forwarded: BrokerForwardOptions
    @Argument var query: String
    func runAsync() async throws {
        let values = try forwarded.values()
        try await runBrokerForwardedCommand(
            "compact_context",
            store: store,
            forwarded: forwarded,
            baseArguments: ["query": .string(query)],
            keepBrokerAlive: values["session_id"] != nil
        )
    }
}

struct MarkdownExportCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "markdown-export", abstract: "Export Markdown compatibility projections")
    @OptionGroup var store: VectorStoreOptions
    @OptionGroup var forwarded: BrokerForwardOptions
    func runAsync() async throws { try await runBrokerForwardedCommand("markdown_export", store: store, forwarded: forwarded) }
}

struct MarkdownSyncCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "markdown-sync", abstract: "Import managed Markdown projections")
    @OptionGroup var store: VectorStoreOptions
    @OptionGroup var forwarded: BrokerForwardOptions
    func runAsync() async throws { try await runBrokerForwardedCommand("markdown_sync", store: store, forwarded: forwarded) }
}
