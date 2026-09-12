import Testing
@testable import Wax

@Suite("MCPHostRegistry")
struct MCPHostRegistryTests {
    @Test func canonicalHostsCoverPrimeAndWireSurfaces() {
        #expect(MCPHostRegistry.Host.allCases.map(\.rawValue) == ["claude", "codex", "grok", "cursor", "opencode", "openclaw"])
    }

    @Test func wireHookSurfaceIsClaudeCodexGrokCursor() {
        #expect(MCPHostRegistry.wireHookNames == ["claude", "codex", "grok", "cursor"])
        #expect(MCPHostRegistry.Host.claude.supportsWireHooks)
        #expect(MCPHostRegistry.Host.cursor.supportsWireHooks)
        #expect(!MCPHostRegistry.Host.opencode.supportsWireHooks)
        #expect(!MCPHostRegistry.Host.openclaw.supportsWireHooks)
    }

    @Test func eventNamesAreHostShaped() {
        #expect(MCPHostRegistry.Host.claude.startEventName == "SessionStart")
        #expect(MCPHostRegistry.Host.claude.endEventName == "SessionEnd")
        #expect(MCPHostRegistry.Host.cursor.startEventName == "sessionStart")
        #expect(MCPHostRegistry.Host.cursor.endEventName == "sessionEnd")
        #expect(MCPHostRegistry.Host.opencode.startEventName == "SessionStart")
    }

    @Test func onlyCodexScopesPrimeWithMatcher() {
        #expect(MCPHostRegistry.Host.codex.primeMatcher == "startup|resume")
        #expect(MCPHostRegistry.Host.claude.primeMatcher == nil)
        #expect(MCPHostRegistry.Host.grok.primeMatcher == nil)
        #expect(MCPHostRegistry.Host.cursor.primeMatcher == nil)
    }

    @Test func cursorPrimeIsOptInOthersAlwaysPrime() {
        #expect(MCPHostRegistry.Host.claude.includesPrime(enableCursorStartHook: false))
        #expect(!MCPHostRegistry.Host.cursor.includesPrime(enableCursorStartHook: false))
        #expect(MCPHostRegistry.Host.cursor.includesPrime(enableCursorStartHook: true))
    }

    @Test func primeFormatFallsBackToJSONWithoutRenderTarget() {
        #expect(MCPHostRegistry.Host.claude.primeFormat == .claude)
        #expect(MCPHostRegistry.Host.codex.primeFormat == .codex)
        #expect(MCPHostRegistry.Host.grok.primeFormat == .grok)
        #expect(MCPHostRegistry.Host.cursor.primeFormat == .cursor)
        #expect(MCPHostRegistry.Host.opencode.primeFormat == .json)
        #expect(MCPHostRegistry.Host.openclaw.primeFormat == .json)
    }

    @Test func unknownHostNameFallsBackToJSON() {
        #expect(MCPHostRegistry.primeFormat(hostName: "claude") == .claude)
        #expect(MCPHostRegistry.primeFormat(hostName: "openclaw") == .json)
        #expect(MCPHostRegistry.primeFormat(hostName: "nope") == .json)
    }

    @Test func onlyCursorUsesFlatDocument() {
        #expect(MCPHostRegistry.Host.claude.usesNestedMatcherDocument)
        #expect(MCPHostRegistry.Host.codex.usesNestedMatcherDocument)
        #expect(MCPHostRegistry.Host.grok.usesNestedMatcherDocument)
        #expect(!MCPHostRegistry.Host.cursor.usesNestedMatcherDocument)
    }
}
