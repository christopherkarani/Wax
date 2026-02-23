import ArgumentParser
import Foundation
import Wax

struct FactAssertCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "fact-assert",
        abstract: "Assert a structured fact (subject-predicate-object triple)"
    )

    @OptionGroup var store: StoreOptions

    @Option(name: .customLong("subject"), help: "Namespaced entity key for the subject (e.g. 'agent:codex')")
    var subject: String

    @Option(name: .customLong("predicate"), help: "Predicate key (e.g. 'learned', 'prefers')")
    var predicate: String

    @Option(name: .customLong("object"), help: "Object value (parsed as int64, then bool, then string)")
    var objectRaw: String

    @Flag(name: .customLong("commit"), inversion: .prefixedNo, help: "Commit immediately (default: true)")
    var commit: Bool = true

    func runAsync() async throws {
        let trimmedSubject = subject.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedSubject.isEmpty else {
            throw CLIError("--subject must not be empty")
        }
        let trimmedPredicate = predicate.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedPredicate.isEmpty else {
            throw CLIError("--predicate must not be empty")
        }
        let trimmedObject = objectRaw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedObject.isEmpty else {
            throw CLIError("--object must not be empty")
        }

        let object = parseObjectValue(trimmedObject)

        let url = try StoreSession.resolveURL(store.storePath)
        let memory = try await StoreSession.open(at: url, noEmbedder: true)
        defer { Task { try? await memory.close() } }

        let factID = try await memory.assertFact(
            subject: EntityKey(trimmedSubject),
            predicate: PredicateKey(trimmedPredicate),
            object: object,
            validFromMs: nil,
            validToMs: nil,
            commit: commit
        )

        switch store.format {
        case .json:
            printJSON([
                "status": "ok",
                "fact_id": factID.rawValue,
                "committed": commit,
            ])
        case .text:
            print("Fact asserted (id \(factID.rawValue), committed: \(commit)).")
        }
    }
}

struct FactRetractCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "fact-retract",
        abstract: "Retract (soft-delete) a structured fact by ID"
    )

    @OptionGroup var store: StoreOptions

    @Option(name: .customLong("fact-id"), help: "Fact row ID to retract")
    var factID: Int64

    @Flag(name: .customLong("commit"), inversion: .prefixedNo, help: "Commit immediately (default: true)")
    var commit: Bool = true

    func runAsync() async throws {
        let url = try StoreSession.resolveURL(store.storePath)
        let memory = try await StoreSession.open(at: url, noEmbedder: true)
        defer { Task { try? await memory.close() } }

        try await memory.retractFact(
            factId: FactRowID(rawValue: factID),
            atMs: nil,
            commit: commit
        )

        switch store.format {
        case .json:
            printJSON([
                "status": "ok",
                "fact_id": factID,
                "committed": commit,
            ])
        case .text:
            print("Fact \(factID) retracted (committed: \(commit)).")
        }
    }
}

struct FactsQueryCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "facts-query",
        abstract: "Query structured facts with optional subject/predicate filters"
    )

    @OptionGroup var store: StoreOptions

    @Option(name: .customLong("subject"), help: "Filter by subject entity key (optional)")
    var subject: String?

    @Option(name: .customLong("predicate"), help: "Filter by predicate key (optional)")
    var predicate: String?

    @Option(name: .customLong("limit"), help: "Max results (1-500, default 20)")
    var limit: Int = 20

    func runAsync() async throws {
        guard limit >= 1, limit <= 500 else {
            throw CLIError("--limit must be between 1 and 500")
        }

        let subjectKey = subject.map { EntityKey($0) }
        let predicateKey = predicate.map { PredicateKey($0) }

        let url = try StoreSession.resolveURL(store.storePath)
        let memory = try await StoreSession.open(at: url, noEmbedder: true)
        defer { Task { try? await memory.close() } }

        let result = try await memory.facts(
            about: subjectKey,
            predicate: predicateKey,
            asOfMs: Int64.max,
            limit: limit
        )

        switch store.format {
        case .json:
            let hits: [[String: Any]] = result.hits.map { hit in
                [
                    "fact_id": hit.factId.rawValue,
                    "subject": hit.fact.subject.rawValue,
                    "predicate": hit.fact.predicate.rawValue,
                    "object": factValueToJSON(hit.fact.object),
                    "is_open_ended": hit.isOpenEnded,
                    "evidence_count": hit.evidence.count,
                ]
            }
            printJSON([
                "count": result.hits.count,
                "truncated": result.wasTruncated,
                "hits": hits,
            ])
        case .text:
            if result.hits.isEmpty {
                print("No facts found.")
            } else {
                print("Found \(result.hits.count) fact(s)\(result.wasTruncated ? " (truncated)" : ""):")
                for hit in result.hits {
                    let objStr = factValueToText(hit.fact.object)
                    print("  [\(hit.factId.rawValue)] \(hit.fact.subject.rawValue) -[\(hit.fact.predicate.rawValue)]-> \(objStr)")
                }
            }
        }
    }
}

// MARK: - CLI value parsing helpers

/// Parse a CLI string into a FactValue: try Int64 first, then Bool, then String.
private func parseObjectValue(_ raw: String) -> FactValue {
    if let intValue = Int64(raw) {
        return .int(intValue)
    }
    switch raw.lowercased() {
    case "true":
        return .bool(true)
    case "false":
        return .bool(false)
    default:
        return .string(raw)
    }
}

/// Serialize a FactValue to a JSON-compatible `Any` for `printJSON`.
private func factValueToJSON(_ value: FactValue) -> Any {
    switch value {
    case .string(let s):
        return s
    case .int(let i):
        return i
    case .double(let d):
        return d
    case .bool(let b):
        return b
    case .entity(let key):
        return ["entity": key.rawValue]
    case .timeMs(let ms):
        return ["time_ms": ms]
    case .data(let d):
        return ["data_base64": d.base64EncodedString()]
    }
}

/// Render a FactValue as a human-readable text string.
private func factValueToText(_ value: FactValue) -> String {
    switch value {
    case .string(let s):
        return "\"\(s)\""
    case .int(let i):
        return String(i)
    case .double(let d):
        return String(d)
    case .bool(let b):
        return String(b)
    case .entity(let key):
        return "entity(\(key.rawValue))"
    case .timeMs(let ms):
        return "timeMs(\(ms))"
    case .data(let d):
        return "data(\(d.count) bytes)"
    }
}
