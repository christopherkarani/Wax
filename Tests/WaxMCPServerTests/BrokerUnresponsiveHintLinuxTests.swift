#if MCPServer && os(Linux)
import Foundation
import Testing
@testable import wax_mcp
@testable import Wax

/// `broker_unresponsive` tells a Linux operator how to restart the HTTP server
/// without naming launchd.
@Test func brokerUnresponsiveNextActionOnLinuxDoesNotNameLaunchctl() {
    let action = WaxMCPTools.brokerUnresponsiveNextAction
    #expect(action.hasPrefix("Restart wax-mcp"))
    #expect(!action.contains("launchctl"))
    #expect(action.contains("session_open with conversation_id"))
    #expect(action.contains("The write did not land; do not spawn children."))
}
#endif
