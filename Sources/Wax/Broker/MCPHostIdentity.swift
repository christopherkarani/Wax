import Foundation
import WaxCore

/// Host conversation isolation key. Equal raw IDs from different hosts do not collide.
package struct HostConversationKey: Hashable, Sendable, Equatable {
    package var hostNamespace: String
    package var conversationID: String
    package var repoIdentity: String

    package init(hostNamespace: String, conversationID: String, repoIdentity: String) {
        self.hostNamespace = hostNamespace.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        self.conversationID = conversationID.trimmingCharacters(in: .whitespacesAndNewlines)
        self.repoIdentity = repoIdentity.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Namespaced conversation ID persisted on the broker manifest.
    package var wireConversationID: String {
        "\(hostNamespace):\(conversationID)"
    }

    package var isUsable: Bool {
        !hostNamespace.isEmpty && !conversationID.isEmpty
    }
}

/// Transport lease key. Client-controlled correlation, not authentication.
package struct MCPTransportKey: Hashable, Sendable, Equatable {
    package var rawConnectionKey: String

    package init(rawConnectionKey: String) {
        self.rawConnectionKey = rawConnectionKey.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    package var hashedConversationID: String {
        let digest = SHA256Checksum.digest(Data(rawConnectionKey.utf8)).hexString
        return "transport:\(digest)"
    }

    package var isUsable: Bool { !rawConnectionKey.isEmpty }
}

package enum MCPMemoryOwnership: String, Sendable, Equatable {
    case transport
    case host
}

package struct MCPClientIdentity: Sendable, Equatable {
    package var name: String?
    package var version: String?
    package var isSyntheticRecovery: Bool

    package static let syntheticRecoveryName = "wax-mcp-session-recover"

    package init(name: String? = nil, version: String? = nil, isSyntheticRecovery: Bool = false) {
        self.name = name
        self.version = version
        self.isSyntheticRecovery = isSyntheticRecovery
            || name == Self.syntheticRecoveryName
    }

    /// Recovery-synthetic identity must never become a host conversation owner.
    package var canOwnHostConversation: Bool {
        !isSyntheticRecovery
    }
}

package struct MCPProjectAttribution: Sendable, Equatable {
    package enum Source: String, Sendable, Equatable {
        case explicit
        case advertisedCWD
        case mcpRoot
        case unresolved
    }

    package var project: String?
    package var repo: String?
    package var cwdPath: String?
    package var source: Source

    package init(
        project: String? = nil,
        repo: String? = nil,
        cwdPath: String? = nil,
        source: Source = .unresolved
    ) {
        self.project = project
        self.repo = repo
        self.cwdPath = cwdPath
        self.source = source
    }

    package var isResolved: Bool {
        source != .unresolved && (project != nil || repo != nil || cwdPath != nil)
    }
}

package struct MCPConnectionContext: Sendable, Equatable {
    package var transportKey: String
    package var advertisedCWD: String?
    package var mcpRoots: [String]
    package var clientIdentity: MCPClientIdentity
    package var trustedHostConversation: HostConversationKey?

    package init(
        transportKey: String,
        advertisedCWD: String? = nil,
        mcpRoots: [String] = [],
        clientIdentity: MCPClientIdentity = MCPClientIdentity(),
        trustedHostConversation: HostConversationKey? = nil
    ) {
        self.transportKey = transportKey
        self.advertisedCWD = advertisedCWD
        self.mcpRoots = mcpRoots
        self.clientIdentity = clientIdentity
        self.trustedHostConversation = trustedHostConversation
    }

    package var canonicalMCPRoot: String? {
        let unique = Array(Set(mcpRoots.map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines)
        }.filter { !$0.isEmpty }))
        return unique.count == 1 ? unique[0] : nil
    }
}

package enum MCPProjectAttributionResolver {
    /// Resolve project/repo from explicit arguments, then advertised cwd, then exactly one MCP root.
    /// Never uses the MCP server process cwd.
    package static func resolve(
        explicitProject: String?,
        explicitRepo: String?,
        advertisedCWD: String?,
        mcpRoots: [String],
        processDirectoryPath: String = "/__wax_unused_process_cwd__"
    ) -> MCPProjectAttribution {
        if let project = normalized(explicitProject), !project.isEmpty {
            let repo = normalized(explicitRepo)
            return MCPProjectAttribution(
                project: project,
                repo: repo,
                cwdPath: normalized(advertisedCWD),
                source: .explicit
            )
        }
        if let repo = normalized(explicitRepo), !repo.isEmpty {
            return MCPProjectAttribution(
                project: nil,
                repo: repo,
                cwdPath: normalized(advertisedCWD),
                source: .explicit
            )
        }
        if let cwd = normalized(advertisedCWD), !cwd.isEmpty {
            let inferred = MemorySemantics.inferScopeContext(
                currentDirectoryPath: cwd,
                processDirectoryPath: processDirectoryPath
            )
            if inferred.projectName != nil || inferred.repoName != nil || inferred.cwdPath != nil {
                return MCPProjectAttribution(
                    project: inferred.projectName,
                    repo: inferred.repoName,
                    cwdPath: inferred.cwdPath ?? cwd,
                    source: .advertisedCWD
                )
            }
        }
        let uniqueRoots = Array(Set((mcpRoots.compactMap(normalized)).filter { !$0.isEmpty }))
        if uniqueRoots.count == 1, let root = uniqueRoots.first {
            let inferred = MemorySemantics.inferScopeContext(
                currentDirectoryPath: root,
                processDirectoryPath: processDirectoryPath
            )
            return MCPProjectAttribution(
                project: inferred.projectName,
                repo: inferred.repoName,
                cwdPath: inferred.cwdPath ?? root,
                source: .mcpRoot
            )
        }
        return MCPProjectAttribution(source: .unresolved)
    }

    package static func isProjectScopedWrite(memoryType: String?, scope: String?) -> Bool {
        if let scope, scope.lowercased() == "global" {
            return false
        }
        let type = memoryType?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if type == MemoryType.userPreference.rawValue, scope?.lowercased() == "global" {
            return false
        }
        if type == MemoryType.userPreference.rawValue {
            return false
        }
        return true
    }

    package static func isProjectGatedRecall(scope: String?) -> Bool {
        let normalizedScope = scope?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? "project"
        return normalizedScope == "project" || normalizedScope.isEmpty
    }

    private static func normalized(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

package enum MCPAutoSessionPolicy {
    package static func isEnabled(
        _ environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Bool {
        let raw = environment["WAX_MCP_AUTO_SESSION"]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        switch raw {
        case "0", "false", "no", "off":
            return false
        default:
            return true
        }
    }
}

package enum MCPInitializeIdentityParser {
    package static func parse(from body: Data) -> MCPClientIdentity {
        guard let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else {
            return MCPClientIdentity()
        }
        return parse(from: json)
    }

    package static func parse(from json: [String: Any]) -> MCPClientIdentity {
        let params = json["params"] as? [String: Any]
        let info = params?["clientInfo"] as? [String: Any]
        let name = info?["name"] as? String
        let version = info?["version"] as? String
        return MCPClientIdentity(name: name, version: version)
    }
}
