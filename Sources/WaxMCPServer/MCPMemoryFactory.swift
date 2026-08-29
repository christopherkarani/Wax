#if MCPServer
import Foundation
import MCP
import Wax
import WaxCore
import WaxVectorSearch

enum MCPPathing {
    static func resolveStoreURL(_ rawPath: String) throws -> URL {
        let expanded = (rawPath as NSString).expandingTildeInPath
        let trimmed = expanded.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw MCP.MCPError.invalidParams("Store path cannot be empty")
        }

        let url = URL(fileURLWithPath: trimmed).standardizedFileURL
        let dir = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: nil)
        return url
    }

    static func resolveDirectoryURL(_ rawPath: String) throws -> URL {
        let expanded = (rawPath as NSString).expandingTildeInPath
        let trimmed = expanded.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw MCP.MCPError.invalidParams("Directory path cannot be empty")
        }

        let url = URL(fileURLWithPath: trimmed).standardizedFileURL
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true, attributes: nil)
        return url
    }
}

enum MCPMemoryFactory {
    private static let defaultLockTimeoutSeconds = 2.0

    static func openMemory(
        at url: URL,
        noEmbedder: Bool,
        embedderChoice: String,
        structuredMemoryEnabled: Bool
    ) async throws -> MemoryOrchestrator {
        let timeout = lockWaitTimeout()
        do {
            try StoreLockProbe.preflightExclusiveAccess(at: url, timeout: timeout)
        } catch {
            throw StoreLockProbe.decorateLockError(
                error,
                at: url,
                timeout: timeout,
                operation: "MCP tool open"
            )
        }
        var config = OrchestratorConfig.default
        config.enableStructuredMemory = structuredMemoryEnabled
        config.enableAccessStatsScoring = true
        let request = try HostEmbeddingReadiness.request(
            noEmbedder: noEmbedder,
            requireVector: false,
            embedderChoice: embedderChoice
        )
        do {
            return try await EmbeddingReadinessBinding.openOrchestrator(
                at: url,
                config: config,
                request: request,
                waxOptions: waxOptions()
            )
        } catch {
            throw StoreLockProbe.decorateLockError(
                error,
                at: url,
                timeout: timeout,
                operation: "MCP tool open"
            )
        }
    }

    static func withOpenMemory<T: Sendable>(
        at url: URL,
        noEmbedder: Bool,
        embedderChoice: String,
        structuredMemoryEnabled: Bool,
        body: (MemoryOrchestrator) async throws -> T
    ) async throws -> T {
        let memory = try await openMemory(
            at: url,
            noEmbedder: noEmbedder,
            embedderChoice: embedderChoice,
            structuredMemoryEnabled: structuredMemoryEnabled
        )

        do {
            let result = try await body(memory)
            try await memory.close()
            return result
        } catch {
            try? await memory.close()
            throw error
        }
    }

    static func openTextOnlyMemory(at url: URL) async throws -> MemoryOrchestrator {
        let timeout = lockWaitTimeout()
        do {
            try StoreLockProbe.preflightExclusiveAccess(at: url, timeout: timeout)
        } catch {
            throw StoreLockProbe.decorateLockError(
                error,
                at: url,
                timeout: timeout,
                operation: "MCP tool open"
            )
        }
        var config = OrchestratorConfig.default
        config.enableVectorSearch = false
        config.rag.searchMode = .textOnly
        config.enableStructuredMemory = false
        config.enableAccessStatsScoring = true
        do {
            return try await MemoryOrchestrator(at: url, config: config, waxOptions: waxOptions())
        } catch {
            throw StoreLockProbe.decorateLockError(
                error,
                at: url,
                timeout: timeout,
                operation: "MCP tool open"
            )
        }
    }

    static func withOpenTextOnlyMemory<T: Sendable>(
        at url: URL,
        body: (MemoryOrchestrator) async throws -> T
    ) async throws -> T {
        let memory = try await openTextOnlyMemory(at: url)
        do {
            let result = try await body(memory)
            try await memory.close()
            return result
        } catch {
            try? await memory.close()
            throw error
        }
    }

    private static func waxOptions() -> WaxOptions {
        var options = WaxOptions()
        options.lockWaitTimeout = lockWaitTimeout()
        return options
    }

    private static func lockWaitTimeout() -> Duration? {
        let env = ProcessInfo.processInfo.environment
        guard let raw = env["WAX_LOCK_TIMEOUT_SECS"]?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty
        else {
            return .milliseconds(Int64(defaultLockTimeoutSeconds * 1000))
        }
        guard let secs = Double(raw) else {
            return .milliseconds(Int64(defaultLockTimeoutSeconds * 1000))
        }
        guard secs > 0 else { return nil }
        return .milliseconds(Int64(secs * 1000))
    }
}
#endif
