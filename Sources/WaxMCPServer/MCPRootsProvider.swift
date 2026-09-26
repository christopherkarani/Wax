#if MCPServer
import Foundation
import MCP

/// Lazily queried MCP client roots, keyed by transport/connection key.
///
/// The provider closure captures the connection's `Server` actor, so it lives
/// in this registry instead of on `MCPClientSessionHint`: the server retains
/// its method handlers, which retain the hint, and actors cannot be held
/// weakly. Entries are removed on transport teardown.
enum MCPRootsProviderRegistry {
    static let shared = Registry()

    final class Registry: @unchecked Sendable {
        private let lock = NSLock()
        private var providers: [String: (@Sendable () async -> [String])] = [:]

        func remember(key: String, provider: @escaping @Sendable () async -> [String]) {
            lock.lock()
            defer { lock.unlock() }
            providers[key] = provider
        }

        func current(key: String) -> (@Sendable () async -> [String])? {
            lock.lock()
            defer { lock.unlock() }
            return providers[key]
        }

        func remove(key: String) {
            lock.lock()
            defer { lock.unlock() }
            providers.removeValue(forKey: key)
        }

        func resetForTests() {
            lock.lock()
            defer { lock.unlock() }
            providers.removeAll()
        }
    }
}

/// `roots/list` fetch with a timeout. Never throws: a missing roots
/// capability, a client that never answers (no HTTP GET stream held), and
/// transport errors all yield an empty list so attribution falls back to
/// explicit `cwd`/`project`/`repo` arguments.
enum MCPRootsFetcher {
    /// Bound for one roots round-trip. Only failing calls pay it: the refresh
    /// runs solely when a project-gated call would otherwise throw.
    static let timeoutSeconds: TimeInterval = 2

    static func fetchRoots(server: Server) async -> [String] {
        await withTaskGroup(of: [String]?.self) { group in
            group.addTask {
                do {
                    let roots = try await server.listRoots()
                    return MCPRootsMapper.paths(fromURIs: roots.map(\.uri))
                } catch {
                    return []
                }
            }
            group.addTask {
                try? await Task.sleep(for: .seconds(timeoutSeconds))
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first ?? []
        }
    }
}

/// MCP root URIs to filesystem paths. Roots must use the `file` scheme;
/// anything else is dropped, never guessed.
enum MCPRootsMapper {
    static func paths(fromURIs uris: [String]) -> [String] {
        uris.compactMap(path(fromURI:))
    }

    static func path(fromURI uri: String) -> String? {
        let trimmed = uri.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let url = URL(string: trimmed),
              url.scheme?.lowercased() == "file",
              !url.path.isEmpty
        else { return nil }
        return url.path
    }
}
#endif
