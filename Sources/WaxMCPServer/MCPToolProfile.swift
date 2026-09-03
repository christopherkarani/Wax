#if MCPServer
import Foundation
import MCP

/// Default MCP `tools/list` is the daily coding loop. Aliases and admin tools
/// stay callable; `WAX_MCP_TOOLS=full` restores the full public catalog.
enum MCPToolProfile: String, Sendable, Equatable {
    case daily
    case full

    static let dailyNames: [String] = [
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

    static func fromEnvironment(
        _ environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> MCPToolProfile {
        let raw = environment["WAX_MCP_TOOLS"]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        switch raw {
        case "full":
            return .full
        default:
            return .daily
        }
    }

    func listed(_ tools: [Tool]) -> [Tool] {
        switch self {
        case .full:
            return tools
        case .daily:
            let byName = Dictionary(tools.map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first })
            return Self.dailyNames.compactMap { byName[$0] }
        }
    }
}
#endif
