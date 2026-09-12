#if MCPServer
import Foundation
import MCP
import Wax

/// MCP `tools/list` profiles.
///
/// - `daily`: coding loop — `remember`, `recall`, `stats`
/// - `legacy`: previous eight-tool playbook
/// - `full`: complete public catalog
///
/// Profile membership lives on `BrokerCommandCatalog`; this type only reads
/// the environment and selects one of the catalog's named views. Hidden tools
/// remain handler-callable. That is not advertised as host UX.
enum MCPToolProfile: String, Sendable, Equatable {
    case daily
    case legacy
    case full

    static var dailyNames: [String] {
        BrokerCommandCatalog.Profile.daily.toolNames
    }

    static var legacyNames: [String] {
        BrokerCommandCatalog.Profile.legacy.toolNames
    }

    static let dailyNameSet = Set(BrokerCommandCatalog.Profile.daily.toolNames)
    static let legacyNameSet = Set(BrokerCommandCatalog.Profile.legacy.toolNames)

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

    var catalogProfile: BrokerCommandCatalog.Profile {
        switch self {
        case .daily:
            return .daily
        case .legacy:
            return .legacy
        case .full:
            return .full
        }
    }
}
#endif
