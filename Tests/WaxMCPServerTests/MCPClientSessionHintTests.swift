#if MCPServer
import Foundation
import Testing
@testable import Wax
@testable import wax_mcp

private func sessionPayload(_ id: UUID) -> AgentBrokerValue {
    .object(["session_id": .string(id.uuidString)])
}

@Test
func sessionEndForAnotherSessionKeepsTheBinding() {
    let key = "hint-stale-end-\(UUID().uuidString)"
    let hint = MCPClientSessionHint(connectionKey: key, context: nil)
    defer { hint.clearBinding() }
    let active = UUID()

    hint.remember(name: "session_start", payload: sessionPayload(active))
    hint.remember(name: "session_end", payload: sessionPayload(UUID()))

    #expect(hint.current() == active)
    #expect(MCPBoundSessionRegistry.shared.current(for: key) == active)
}

@Test
func sessionEndForTheBoundSessionClearsHintAndRegistry() {
    let key = "hint-end-\(UUID().uuidString)"
    let hint = MCPClientSessionHint(connectionKey: key, context: nil)
    defer { hint.clearBinding() }
    let active = UUID()

    hint.remember(name: "session_start", payload: sessionPayload(active))
    hint.remember(name: "session_close", payload: sessionPayload(active))

    #expect(hint.current() == nil)
    #expect(MCPBoundSessionRegistry.shared.current(for: key) == nil)
}

/// Ending the old session and starting a new one at the same time must always
/// leave the new one bound: either the end runs first and the start rebinds, or
/// the start runs first and the end no longer matches.
@Test
func concurrentEndOfOldSessionNeverDropsTheNewOne() async {
    for _ in 0..<200 {
        let key = "hint-race-\(UUID().uuidString)"
        let hint = MCPClientSessionHint(connectionKey: key, context: nil)
        let old = UUID()
        let new = UUID()
        hint.remember(name: "session_start", payload: sessionPayload(old))

        await withTaskGroup(of: Void.self) { group in
            group.addTask { hint.remember(name: "session_end", payload: sessionPayload(old)) }
            group.addTask { hint.remember(name: "session_start", payload: sessionPayload(new)) }
        }

        #expect(hint.current() == new)
        #expect(MCPBoundSessionRegistry.shared.current(for: key) == new)
        hint.clearBinding()
    }
}
#endif
