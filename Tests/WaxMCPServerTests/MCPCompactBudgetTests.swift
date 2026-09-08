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
}
#endif
