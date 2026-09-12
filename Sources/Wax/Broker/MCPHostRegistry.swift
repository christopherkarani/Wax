/// Single host vocabulary for the hook-wiring and prime surfaces.
///
/// `HostHookHost` (wire-hooks), `MCPPrimeHost` (prime), and
/// `MCPPrimeAssembly.Format` (render) each named the same hosts with
/// slightly different membership. This module owns the canonical host list
/// and every host-varying policy; those three shapes are thin adapters over
/// this interface.
package enum MCPHostRegistry {
    package enum Host: String, Sendable, CaseIterable {
        case claude
        case codex
        case grok
        case cursor
        case opencode
        case openclaw

        /// Hosts the wire-hooks path can merge configs for.
        package var supportsWireHooks: Bool {
            switch self {
            case .claude, .codex, .grok, .cursor:
                return true
            case .opencode, .openclaw:
                return false
            }
        }

        package var startEventName: String {
            switch self {
            case .cursor:
                return "sessionStart"
            case .claude, .codex, .grok, .opencode, .openclaw:
                return "SessionStart"
            }
        }

        package var endEventName: String {
            switch self {
            case .cursor:
                return "sessionEnd"
            case .claude, .codex, .grok, .opencode, .openclaw:
                return "SessionEnd"
            }
        }

        /// Only codex scopes its prime hook behind a matcher.
        package var primeMatcher: String? {
            switch self {
            case .codex:
                return "startup|resume"
            case .claude, .grok, .cursor, .opencode, .openclaw:
                return nil
            }
        }

        /// Cursor prime is opt-in; every other host always primes.
        package func includesPrime(enableCursorStartHook: Bool) -> Bool {
            switch self {
            case .cursor:
                return enableCursorStartHook
            case .claude, .codex, .grok, .opencode, .openclaw:
                return true
            }
        }

        /// Only cursor needs a live-injection probe on its prime entry.
        package var requiresLiveInjectionProbeForPrime: Bool {
            self == .cursor
        }

        /// Render shape for prime output. Hosts without a dedicated renderer
        /// fall back to `.json` explicitly instead of a silent nil-coalesce.
        package var primeFormat: MCPPrimeAssembly.Format {
            MCPPrimeAssembly.Format(rawValue: rawValue) ?? .json
        }

        /// Document shape for hook-config merge. Only cursor uses the flat
        /// versioned document; the rest share the nested-matcher shape.
        package var usesNestedMatcherDocument: Bool {
            self != .cursor
        }
    }

    /// Hosts accepted by `mcp wire-hooks`, in wiring order.
    package static var wireHookNames: [String] {
        Host.allCases.filter(\.supportsWireHooks).map(\.rawValue)
    }

    /// Resolve a prime render format for any host string, defaulting to
    /// `.json` for unknown names instead of scattering `?? .json` fallbacks.
    package static func primeFormat(hostName: String) -> MCPPrimeAssembly.Format {
        Host(rawValue: hostName)?.primeFormat ?? .json
    }
}
