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
        let result = WaxMCPTools.renderResult(name: "compact_context", payload: payload, verbosity: .compact)
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
        ]), verbosity: .verbose)
        let text = try #require(result.content.compactMap { block -> String? in
            if case .text(let value, _, _) = block { return value }
            return nil
        }.first)
        #expect(text.contains("/fixture/memory.wax"))
        #expect(!text.contains("Duplicated narrative"))
    }

    @Test func rememberCompactKeepsMinimalVerifiableEcho() throws {
        let content = "C01 GitLiveProbe stays intent until this tree has the type."
        let full: AgentBrokerValue = .object([
            "status": .string("ok"),
            "committed": .bool(true),
            "frame_id": .int(42),
            "memory_id": .string("durable:42"),
            "framesAdded": .int(1),
            "frameCount": .int(9),
            "pendingFrames": .int(0),
            "scope": .string("durable"),
            "session_id": .null,
            "memory_type": .string("note"),
            "durability": .string("working"),
            "deduplicated": .bool(false),
            "searchable": .bool(true),
            "echo": .string(content),
            "echo_truncated": .bool(false),
            "content_sha8": .string("5dc5ef31"),
            "stored": .string(content),
            "stored_truncated": .bool(false),
            "chunked": .bool(false),
            "chunk_count": .int(1),
            "content_bytes": .int(59),
            "unresolved_project": .bool(false),
            "display_text": .string("Full content stored (59 bytes, sha 5dc5ef31); echo shows first 240 chars."),
            "project": .string("wax"),
            "repo": .string("wax"),
        ])
        let compact = WaxMCPTools.renderResult(name: "remember", payload: full, verbosity: .compact)
        let compactText = try #require(compact.content.compactMap { block -> String? in
            if case .text(let value, _, _) = block { return value }
            return nil
        }.first)
        for key in [
            "\"status\"", "\"committed\"", "\"memory_id\"", "\"frame_id\"", "\"scope\"",
            "\"content_bytes\"", "\"content_sha8\"", "\"echo\"", "\"echo_truncated\"",
            "\"project\"", "\"repo\"",
        ] {
            #expect(compactText.contains(key), "compact remember drops \(key): \(compactText)")
        }
        #expect(compactText.contains(content))
        #expect(compactText.contains("5dc5ef31"))
        for key in [
            "\"framesAdded\"", "\"frameCount\"", "\"pendingFrames\"", "\"session_id\"",
            "\"memory_type\"", "\"durability\"", "\"deduplicated\"", "\"searchable\"",
            "\"stored\"", "\"stored_truncated\"", "\"chunked\"", "\"chunk_count\"",
            "\"unresolved_project\"", "\"display_text\"",
        ] {
            if compactText.contains(key) {
                Issue.record("compact remember leaks verbose-only \(key): \(compactText)")
            }
        }

        let verbose = WaxMCPTools.renderResult(name: "remember", payload: full, verbosity: .verbose)
        let verboseText = try #require(verbose.content.compactMap { block -> String? in
            if case .text(let value, _, _) = block { return value }
            return nil
        }.first)
        #expect(verboseText.contains("\"memory_type\""))
        #expect(verboseText.contains("\"deduplicated\""))
        #expect(verboseText.contains("\"stored\""))
        #expect(verboseText.contains("\"stored_truncated\""))
        #expect(verboseText.contains("\"echo\""))
        if verboseText.contains("Full content stored") {
            Issue.record("verbose remember still includes display_text: \(verboseText)")
        }
    }

    @Test func rememberCompactAppliesToMemoryAppendAlias() throws {
        let result = WaxMCPTools.renderResult(
            name: "memory_append",
            payload: .object([
                "status": .string("ok"),
                "committed": .bool(true),
                "memory_id": .string("durable:7"),
                "echo": .string("alias echo"),
                "memory_type": .string("note"),
                "display_text": .string("Full content stored (10 bytes, sha deadbeef); echo shows first 240 chars."),
            ]),
            verbosity: .compact
        )
        let text = try #require(result.content.compactMap { block -> String? in
            if case .text(let value, _, _) = block { return value }
            return nil
        }.first)
        #expect(text.contains("alias echo"))
        if text.contains("memory_type") || text.contains("display_text") {
            Issue.record("compact memory_append leaks verbose-only keys: \(text)")
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
            verbosity: .compact
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
