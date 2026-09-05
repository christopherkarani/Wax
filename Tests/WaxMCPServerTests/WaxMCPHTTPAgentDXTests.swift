#if MCPServer
import Foundation
import MCP
import Testing
@testable import wax_mcp

struct WaxMCPHTTPAgentDXTests {
    @Test
    func loopbackHTTPRejectsDNSRebindingHostAndForeignOrigin() async throws {
        #expect(HTTPAuthPolicy.isSafeLoopbackRequest(
            hostHeader: "127.0.0.1:3000",
            originHeader: "http://localhost:3000"
        ))
        #expect(HTTPAuthPolicy.isSafeLoopbackRequest(
            hostHeader: "[::1]:3000",
            originHeader: nil
        ))
        #expect(HTTPAuthPolicy.isSafeLoopbackRequest(
            hostHeader: "localhost:3000",
            originHeader: "http://127.0.0.1:3000"
        ))
        #expect(HTTPAuthPolicy.isSafeLoopbackRequest(
            hostHeader: "attacker.example:3000",
            originHeader: nil
        ) == false)
        #expect(HTTPAuthPolicy.isSafeLoopbackRequest(
            hostHeader: "127.0.0.1.attacker.example:3000",
            originHeader: nil
        ) == false)
        #expect(HTTPAuthPolicy.isSafeLoopbackRequest(
            hostHeader: "127.0.0.1:3000",
            originHeader: "https://attacker.example"
        ) == false)
        #expect(HTTPAuthPolicy.isSafeLoopbackRequest(
            hostHeader: "127.0.0.1:3000",
            originHeader: "http://127.0.0.1.attacker.example"
        ) == false)
        #expect(HTTPAuthPolicy.isSafeLoopbackRequest(
            hostHeader: "127.0.0.1:3000",
            originHeader: "null"
        ) == false)
        #expect(HTTPAuthPolicy.isSafeLoopbackRequest(
            hostHeader: "127.0.0.1:3000",
            originHeader: "http://evil.com@127.0.0.1"
        ) == false)

        let initializeBody = try JSONSerialization.data(withJSONObject: [
            "jsonrpc": "2.0",
            "id": 1,
            "method": "initialize",
            "params": [
                "protocolVersion": "2024-11-05",
                "capabilities": [:] as [String: Any],
                "clientInfo": ["name": "wax-http-dx", "version": "0"],
            ],
        ])
        let statsBody = try JSONSerialization.data(withJSONObject: [
            "jsonrpc": "2.0",
            "id": 2,
            "method": "tools/call",
            "params": [
                "name": "stats",
                "arguments": [:] as [String: Any],
            ],
        ])

        let rejectingApp = MCPHTTPApplication(
            serverFactory: { _, _ in
                Issue.record("foreign Host or Origin must not create an MCP session")
                throw MCP.MCPError.invalidRequest("unexpected server creation")
            }
        )

        let foreignHost = await rejectingApp.handleHTTPRequest(HTTPRequest(
            method: "POST",
            headers: [
                "Content-Type": "application/json",
                "Accept": "application/json, text/event-stream",
                "Host": "attacker.example:3000",
            ],
            body: initializeBody,
            path: "/mcp"
        ))
        #expect(foreignHost.statusCode == 403)

        let rebindingSuffix = await rejectingApp.handleHTTPRequest(HTTPRequest(
            method: "POST",
            headers: [
                "Content-Type": "application/json",
                "Accept": "application/json, text/event-stream",
                "Host": "127.0.0.1.attacker.example:3000",
            ],
            body: initializeBody,
            path: "/mcp"
        ))
        #expect(rebindingSuffix.statusCode == 403)

        let foreignOrigin = await rejectingApp.handleHTTPRequest(HTTPRequest(
            method: "POST",
            headers: [
                "Content-Type": "application/json",
                "Accept": "application/json, text/event-stream",
                "Host": "127.0.0.1:3000",
                "Origin": "https://attacker.example",
            ],
            body: initializeBody,
            path: "/mcp"
        ))
        #expect(foreignOrigin.statusCode == 403)

        let userinfoOrigin = await rejectingApp.handleHTTPRequest(HTTPRequest(
            method: "POST",
            headers: [
                "Content-Type": "application/json",
                "Accept": "application/json, text/event-stream",
                "Host": "127.0.0.1:3000",
                "Origin": "http://evil.com@127.0.0.1",
            ],
            body: initializeBody,
            path: "/mcp"
        ))
        #expect(userinfoOrigin.statusCode == 403)

        let app = MCPHTTPApplication(
            serverFactory: { _, _ in
                Server(
                    name: "wax-mcp-http-dx",
                    version: "0.0.0",
                    capabilities: .init(tools: .init(listChanged: false))
                )
            }
        )

        let initialized = await app.handleHTTPRequest(HTTPRequest(
            method: "POST",
            headers: [
                "Content-Type": "application/json",
                "Accept": "application/json, text/event-stream",
                "Host": "127.0.0.1:3000",
                "Origin": "http://localhost:3000",
            ],
            body: initializeBody,
            path: "/mcp"
        ))
        #expect(initialized.statusCode == 200)
        let sessionID = try #require(initialized.headers[HTTPHeaderName.sessionID])

        let stats = await app.handleHTTPRequest(HTTPRequest(
            method: "POST",
            headers: [
                "Content-Type": "application/json",
                "Accept": "application/json, text/event-stream",
                "Host": "127.0.0.1:3000",
                "Origin": "http://localhost:3000",
                HTTPHeaderName.sessionID: sessionID,
            ],
            body: statsBody,
            path: "/mcp"
        ))
        #expect(stats.statusCode != 403)
        #expect(stats.statusCode != 401)

        let closed = await app.handleHTTPRequest(HTTPRequest(
            method: "DELETE",
            headers: [
                "Host": "127.0.0.1:3000",
                "Origin": "http://localhost:3000",
                HTTPHeaderName.sessionID: sessionID,
            ],
            path: "/mcp"
        ))
        #expect(closed.statusCode == 200)
    }

    @Test
    func dailyToolProfileMatchesDoctorCanonicalVerbs() {
        #expect(MCPToolProfile.dailyNames == [
            "session_open",
            "remember",
            "recall",
            "session_close",
            "stats",
            "memory_get",
            "compact_context",
            "session_resume",
        ])
    }
}
#endif
