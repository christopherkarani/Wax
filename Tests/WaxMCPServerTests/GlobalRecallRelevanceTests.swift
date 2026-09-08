#if MCPServer
import Foundation
import Testing
@testable import Wax

@Suite("Global recall relevance")
struct GlobalRecallRelevanceTests {
    @Test
    func globalRecallDoesNotBackfillWorkingNotesExcludedByQueryOrFilters() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("wax-global-relevance-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let service = try await AgentBrokerService(
            storePath: root.appendingPathComponent("memory.wax").path,
            sessionRootPath: root.appendingPathComponent("sessions").path,
            noEmbedder: true,
            embedderChoice: "auto",
            requireVector: false
        )
        do {
            let opened = await service.handle(.init(command: "session_open", arguments: [
                "project": .string("global-relevance"),
                "agent_id": .string("global-relevance-agent"),
                "run_id": .string(UUID().uuidString),
            ]))
            #expect(opened.ok)
            let sessionID = try #require(opened.payload?.objectValue?["session_id"]?.stringValue)
            let remembered = await service.handle(.init(command: "remember", arguments: [
                "session_id": .string(sessionID),
                "content": .string("Bananas make a pleasant smoothie."),
                "memory_type": .string("task_state"),
            ]))
            #expect(remembered.ok)

            let cases: [(String, AgentBrokerValue?)] = [
                ("UNMATCHEDZXQJ", nil),
                ("Bananas", .object(["metadata": .object(["wax.memory_type": .string("lesson")])])),
                ("Bananas", .object(["time_before_ms": .int(1)])),
            ]
            for (query, filters) in cases {
                var arguments: [String: AgentBrokerValue] = [
                    "session_id": .string(sessionID),
                    "query": .string(query),
                    "scope": .string("global"),
                    "mode": .string("text"),
                ]
                if let filters { arguments["filters"] = filters }
                let response = await service.handle(.init(command: "recall", arguments: arguments))
                #expect(response.ok)
                let results = try #require(response.payload?.objectValue?["results"]?.arrayValue)
                #expect(results.isEmpty, "Global recall must respect query and filters: \(query)")
            }

            let matched = await service.handle(.init(command: "recall", arguments: [
                "session_id": .string(sessionID),
                "query": .string("Bananas"),
                "scope": .string("global"),
                "mode": .string("text"),
            ]))
            #expect(matched.ok)
            let matches = try #require(matched.payload?.objectValue?["results"]?.arrayValue)
            #expect(matches.contains { $0.objectValue?["text"]?.stringValue?.contains("Bananas") == true })
            try await service.close()
        } catch {
            try? await service.close()
            throw error
        }
    }
}
#endif
