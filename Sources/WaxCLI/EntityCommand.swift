import ArgumentParser
import Foundation
import Wax

struct EntityUpsertCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "entity-upsert",
        abstract: "Create or update an entity in structured memory"
    )

    @OptionGroup var store: StoreOptions

    @Option(name: .customLong("key"), help: "Namespaced entity key (e.g. 'agent:codex')")
    var key: String

    @Option(name: .customLong("kind"), help: "Entity kind (e.g. 'agent', 'project')")
    var kind: String

    @Option(name: .customLong("aliases"), help: "Comma-separated aliases (e.g. 'codex,assistant')")
    var aliasesRaw: String?

    @Flag(name: .customLong("commit"), inversion: .prefixedNo, help: "Commit immediately (default: true)")
    var commit: Bool = true

    func runAsync() async throws {
        let trimmedKey = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedKey.isEmpty else {
            throw CLIError("--key must not be empty")
        }
        let trimmedKind = kind.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedKind.isEmpty else {
            throw CLIError("--kind must not be empty")
        }

        let aliases: [String] = aliasesRaw?
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty } ?? []

        let url = try StoreSession.resolveURL(store.storePath)
        let memory = try await StoreSession.open(at: url, noEmbedder: true)
        defer { Task { try? await memory.close() } }

        let entityID = try await memory.upsertEntity(
            key: EntityKey(trimmedKey),
            kind: trimmedKind,
            aliases: aliases,
            commit: commit
        )

        switch store.format {
        case .json:
            printJSON([
                "status": "ok",
                "entity_id": entityID.rawValue,
                "key": trimmedKey,
                "committed": commit,
            ])
        case .text:
            print("Entity upserted: \(trimmedKey) (id \(entityID.rawValue), committed: \(commit))")
        }
    }
}

struct EntityResolveCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "entity-resolve",
        abstract: "Resolve entities by alias"
    )

    @OptionGroup var store: StoreOptions

    @Option(name: .customLong("alias"), help: "Alias to search for")
    var alias: String

    @Option(name: .customLong("limit"), help: "Max results (1-100, default 10)")
    var limit: Int = 10

    func runAsync() async throws {
        let trimmedAlias = alias.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedAlias.isEmpty else {
            throw CLIError("--alias must not be empty")
        }
        guard limit >= 1, limit <= 100 else {
            throw CLIError("--limit must be between 1 and 100")
        }

        let url = try StoreSession.resolveURL(store.storePath)
        let memory = try await StoreSession.open(at: url, noEmbedder: true)
        defer { Task { try? await memory.close() } }

        let matches = try await memory.resolveEntities(matchingAlias: trimmedAlias, limit: limit)

        switch store.format {
        case .json:
            let entities: [[String: Any]] = matches.map { match in
                [
                    "id": match.id,
                    "key": match.key.rawValue,
                    "kind": match.kind,
                ]
            }
            printJSON([
                "count": matches.count,
                "entities": entities,
            ])
        case .text:
            if matches.isEmpty {
                print("No entities found for alias '\(trimmedAlias)'.")
            } else {
                print("Found \(matches.count) entit\(matches.count == 1 ? "y" : "ies"):")
                for match in matches {
                    print("  [\(match.id)] \(match.key.rawValue) (\(match.kind))")
                }
            }
        }
    }
}
