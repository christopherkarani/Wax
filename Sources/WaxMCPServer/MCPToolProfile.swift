#if MCPServer
import Foundation
import MCP

/// MCP `tools/list` profiles.
///
/// - `daily`: coding loop — `remember`, `recall`, `stats`
/// - `legacy`: previous eight-tool playbook
/// - `full`: complete public catalog
///
/// Hidden tools remain handler-callable. That is not advertised as host UX.
enum MCPToolProfile: String, Sendable, Equatable {
    case daily
    case legacy
    case full

    static let dailyNames: [String] = [
        "remember",
        "recall",
        "stats",
    ]

    static let legacyNames: [String] = [
        "session_open",
        "remember",
        "recall",
        "session_close",
        "stats",
        "memory_get",
        "compact_context",
        "session_resume",
    ]

    static let dailyNameSet = Set(dailyNames)
    static let legacyNameSet = Set(legacyNames)

    static func fromEnvironment(
        _ environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> MCPToolProfile {
        let raw = environment["WAX_MCP_TOOLS"]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        switch raw {
        case "full":
            return .full
        case "legacy":
            return .legacy
        default:
            return .daily
        }
    }

    var listedNames: [String] {
        switch self {
        case .daily:
            return Self.dailyNames
        case .legacy:
            return Self.legacyNames
        case .full:
            return []
        }
    }

    func listed(_ tools: [Tool]) -> [Tool] {
        switch self {
        case .full:
            return tools
        case .daily, .legacy:
            let byName = Dictionary(tools.map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first })
            return listedNames.compactMap { byName[$0] }
        }
    }
}
#endif
