#if MCPServer
import Foundation
import MCP
import Testing
@testable import Wax
@testable import wax_mcp

@Suite struct MCPCompactBudgetTests {
    @Test func compactCheckpointDoesNotRepeatUnbudgetedMemoryBodies() throws {
        let body = String(repeating: "large unbudgeted memory body ", count: 5_000)
        let payload: AgentBrokerValue = .object([
            "token_budget": .int(100), "used_tokens": .int(5),
            "compacted_text": .string("The budgeted checkpoint."),
            "summary": .string("A duplicate summary."),
            "short_context": .array([.object([
                "memory_id": .string("working:session:0"),
                "text": .string(body), "preview": .string("Repeated preview."),
            ])]),
        ])
        let result = WaxMCPTools.renderResult(name: "compact_context", payload: payload, verbosity: "compact")
        let text = try #require(result.content.compactMap { block -> String? in
            if case .text(let value, _, _) = block { return value }
            return nil
        }.first)
        #expect(text.utf8.count < 1_000)
        #expect(text.contains("The budgeted checkpoint."))
        #expect(text.contains("working:session:0"))
        #expect(!text.contains("Repeated preview."))
        #expect(!text.contains("A duplicate summary."))
    }

    @Test func verboseKeepsOperatorDiagnostics() throws {
        let result = WaxMCPTools.renderResult(name: "stats", payload: .object([
            "store_path": .string("/fixture/memory.wax"),
            "display_text": .string("Duplicated narrative"),
        ]), verbosity: "verbose")
        let text = try #require(result.content.compactMap { block -> String? in
            if case .text(let value, _, _) = block { return value }
            return nil
        }.first)
        #expect(text.contains("/fixture/memory.wax"))
        #expect(!text.contains("Duplicated narrative"))
    }

    @Test func rememberCompactKeepsStoredEcho() throws {
        let content = "C01 GitLiveProbe stays intent until this tree has the type."
        let result = WaxMCPTools.renderResult(
            name: "remember",
            payload: .object([
                "status": .string("ok"),
                "committed": .bool(true),
                "memory_id": .string("durable:42"),
                "searchable": .bool(true),
                "stored": .string(content),
                "display_text": .string("Remembered. 1 frame(s) added."),
            ]),
            verbosity: "compact"
        )
        let text = try #require(result.content.compactMap { block -> String? in
            if case .text(let value, _, _) = block { return value }
            return nil
        }.first)
        #expect(text.contains("\"stored\""))
        #expect(text.contains(content))
        #expect(text.contains("durable:42"))
        if text.contains("Remembered. 1 frame(s) added.") {
            Issue.record("compact remember still includes display_text: \(text)")
        }
    }

    @Test func recallCompactKeepsSummary() throws {
        let result = WaxMCPTools.renderResult(
            name: "recall",
            payload: .object([
                "summary": .string("1. [constraint] C01 GitLiveProbe · aaaaaaa · other"),
                "collapsed": .int(3),
                "display_text": .string("Duplicated narrative"),
                "results": .array([]),
            ]),
            verbosity: "compact"
        )
        let text = try #require(result.content.compactMap { block -> String? in
            if case .text(let value, _, _) = block { return value }
            return nil
        }.first)
        #expect(text.contains("1. [constraint] C01 GitLiveProbe"))
        #expect(text.contains("\"collapsed\":3") || text.contains("\"collapsed\": 3"))
        #expect(!text.contains("Duplicated narrative"))
    }
}
#endif
