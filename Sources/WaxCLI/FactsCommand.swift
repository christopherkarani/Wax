import ArgumentParser
import Foundation
import Wax

struct FactAssertCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "fact-assert",
        abstract: "Assert a structured fact (subject-predicate-object triple)"
    )

    @OptionGroup var store: VectorStoreOptions

    @Option(name: .customLong("subject"), help: "Namespaced entity key for the subject (e.g. 'agent:codex')")
    var subject: String

    @Option(name: .customLong("predicate"), help: "Predicate key (e.g. 'learned', 'prefers')")
    var predicate: String

    @Option(name: .customLong("object"), help: "Object value (parsed as int64, then bool, then string)")
    var objectRaw: String

    @Option(name: .customLong("relation"), help: "Version relation: sets, updates, extends, retracts")
    var relation: String = "sets"

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
        let parsedRelation = try parseVersionRelation(relation)

        let object = parseObjectValue(trimmedObject)

        if AgentBrokerPolicy.shouldUseBroker(store: store, commit: commit) {
            let response = try await AgentBrokerCLI.perform(
                command: "fact_assert",
                arguments: [
                    "subject": .string(trimmedSubject),
                    "predicate": .string(trimmedPredicate),
                    "object": factValueToBrokerValue(object),
                    "relation": .string(relation),
                ],
                storePath: store.storePath,
                embedderChoice: store.embedder.rawValue,
                noEmbedder: store.noEmbedder,
                requireVector: store.requireVector,
                embedderTuning: store.embedderTuning
            )
            let payload = try brokerPayloadObject(response)
            let factID = brokerInt64(payload, "fact_id") ?? 0
            switch store.format {
            case .json:
                printJSON([
                    "status": "ok",
                    "fact_id": factID,
                    "committed": true,
                ])
            case .text:
                print("Fact asserted (id \(factID), committed: true).")
            }
            return
        }

        let url = try StoreSession.resolveURL(store.storePath)
        try await StoreSession.withOpen(at: url, noEmbedder: true) { memory in
            let factID = try await memory.assertFact(
                subject: EntityKey(trimmedSubject),
                predicate: PredicateKey(trimmedPredicate),
                object: object,
                relation: parsedRelation,
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
}

struct FactRetractCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "fact-retract",
        abstract: "Retract (soft-delete) a structured fact by ID"
    )

    @OptionGroup var store: VectorStoreOptions

    @Option(name: .customLong("fact-id"), help: "Fact row ID to retract")
    var factID: Int64

    @Flag(name: .customLong("commit"), inversion: .prefixedNo, help: "Commit immediately (default: true)")
    var commit: Bool = true

    func runAsync() async throws {
        if AgentBrokerPolicy.shouldUseBroker(store: store, commit: commit) {
            let response = try await AgentBrokerCLI.perform(
                command: "fact_retract",
                arguments: [
                    "fact_id": .from(factID),
                ],
                storePath: store.storePath,
                embedderChoice: store.embedder.rawValue,
                noEmbedder: store.noEmbedder,
                requireVector: store.requireVector,
                embedderTuning: store.embedderTuning
            )
            let payload = try brokerPayloadObject(response)
            let retractedID = brokerInt64(payload, "fact_id") ?? factID
            switch store.format {
            case .json:
                printJSON([
                    "status": "ok",
                    "fact_id": retractedID,
                    "committed": true,
                ])
            case .text:
                print("Fact \(retractedID) retracted (committed: true).")
            }
            return
        }

        let url = try StoreSession.resolveURL(store.storePath)
        try await StoreSession.withOpen(at: url, noEmbedder: true) { memory in
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
}

struct FactsQueryCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "facts-query",
        abstract: "Query structured facts with optional subject/predicate filters"
    )

    @OptionGroup var store: VectorStoreOptions

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

        if AgentBrokerPolicy.shouldUseBroker(store: store) {
            let response = try await AgentBrokerCLI.perform(
                command: "facts_query",
                arguments: [
                    "subject": .from(subject),
                    "predicate": .from(predicate),
                    "limit": .from(limit),
                ],
                storePath: store.storePath,
                embedderChoice: store.embedder.rawValue,
                noEmbedder: store.noEmbedder,
                requireVector: store.requireVector,
                embedderTuning: store.embedderTuning
            )
            let payload = try brokerPayloadObject(response)
            let hits = brokerArray(payload, "hits")
            switch store.format {
            case .json:
                printJSON(payload.toJSONObject())
            case .text:
                if hits.isEmpty {
                    print("No facts found.")
                } else {
                    print("Found \(hits.count) fact(s):")
                    for hit in hits {
                        guard let object = hit.objectValue else { continue }
                        let objStr = factValueToText(brokerValueToFactValue(object["object"] ?? .null))
                        let factId = brokerInt64(object, "fact_id") ?? 0
                        let spanId = brokerInt64(object, "span_id") ?? 0
                        print(factTextLine(
                            factId: factId,
                            spanId: spanId,
                            subject: brokerString(object, "subject") ?? "",
                            predicate: brokerString(object, "predicate") ?? "",
                            objectText: objStr,
                            validFromMs: brokerInt64(object, "valid_from_ms") ?? 0,
                            validToMs: brokerInt64(object, "valid_to_ms"),
                            systemFromMs: brokerInt64(object, "system_from_ms") ?? 0,
                            systemToMs: brokerInt64(object, "system_to_ms")
                        ))
                    }
                }
            }
            return
        }

        let url = try StoreSession.resolveURL(store.storePath)
        try await StoreSession.withOpen(at: url, noEmbedder: true) { memory in
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
                        "span_id": hit.spanId,
                        "subject": hit.fact.subject.rawValue,
                        "predicate": hit.fact.predicate.rawValue,
                        "object": factValueToJSON(hit.fact.object),
                        "valid_from_ms": hit.valid.fromMs,
                        "valid_to_ms": hit.valid.toMs ?? NSNull(),
                        "system_from_ms": hit.system.fromMs,
                        "system_to_ms": hit.system.toMs ?? NSNull(),
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
                        print(factTextLine(
                            factId: hit.factId.rawValue,
                            spanId: hit.spanId,
                            subject: hit.fact.subject.rawValue,
                            predicate: hit.fact.predicate.rawValue,
                            objectText: objStr,
                            validFromMs: hit.valid.fromMs,
                            validToMs: hit.valid.toMs,
                            systemFromMs: hit.system.fromMs,
                            systemToMs: hit.system.toMs
                        ))
                    }
                }
            }
        }
    }
}

// MARK: - CLI value parsing helpers

/// Parse a CLI string into a FactValue: try Int64 first, then Double, then Bool, then String.
private func parseObjectValue(_ raw: String) -> FactValue {
    if let intValue = Int64(raw) {
        return .int(intValue)
    }
    if let doubleValue = Double(raw), raw.contains(".") || raw.lowercased().contains("e") {
        return .double(doubleValue)
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

private func parseVersionRelation(_ raw: String) throws -> VersionRelation {
    switch raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
    case "sets":
        return .sets
    case "updates":
        return .updates
    case "extends":
        return .extends
    case "retracts":
        return .retracts
    default:
        throw CLIError("--relation must be one of: sets, updates, extends, retracts")
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

func factTextLine(
    factId: Int64,
    spanId: Int64,
    subject: String,
    predicate: String,
    objectText: String,
    validFromMs: Int64,
    validToMs: Int64?,
    systemFromMs: Int64,
    systemToMs: Int64?
) -> String {
    let valid = factTimeRangeText(fromMs: validFromMs, toMs: validToMs)
    let system = factTimeRangeText(fromMs: systemFromMs, toMs: systemToMs)
    return "  [\(factId):\(spanId)] \(subject) -[\(predicate)]-> \(objectText) valid=\(valid) system=\(system)"
}

private func factTimeRangeText(fromMs: Int64, toMs: Int64?) -> String {
    "[\(fromMs)..\(toMs.map(String.init) ?? "open")]"
}

private func factValueToBrokerValue(_ value: FactValue) -> AgentBrokerValue {
    switch value {
    case .string(let s):
        return .string(s)
    case .int(let i):
        return .int(i)
    case .double(let d):
        return .double(d)
    case .bool(let b):
        return .bool(b)
    case .entity(let key):
        return .object(["entity": .string(key.rawValue)])
    case .timeMs(let ms):
        return .object(["time_ms": .int(ms)])
    case .data(let data):
        return .object(["data_base64": .string(data.base64EncodedString())])
    }
}

private func brokerValueToFactValue(_ value: AgentBrokerValue) -> FactValue {
    switch value {
    case .string(let s):
        return .string(s)
    case .int(let i):
        return .int(i)
    case .double(let d):
        return .double(d)
    case .bool(let b):
        return .bool(b)
    case .object(let object):
        if let entity = object["entity"]?.stringValue {
            return .entity(EntityKey(entity))
        }
        if let time = object["time_ms"]?.intValue {
            return .timeMs(time)
        }
        if let data = object["data_base64"]?.stringValue, let decoded = Data(base64Encoded: data) {
            return .data(decoded)
        }
        return .string("")
    default:
        return .string("")
    }
}
