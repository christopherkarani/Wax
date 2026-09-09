import Foundation
import Testing
@testable import Wax

@Test
func recallPresentAgeDaysUsesWholeDaysAndClamps() {
    #expect(RecallPresent.ageDays(createdAtMs: 0, nowMs: 10_000) == 0)
    #expect(RecallPresent.ageDays(createdAtMs: -1, nowMs: 10_000) == 0)
    let dayMs: Int64 = 1000 * 60 * 60 * 24
    #expect(RecallPresent.ageDays(createdAtMs: 1_000, nowMs: 1_000 + (2 * dayMs) + 5) == 2)
    #expect(RecallPresent.ageDays(createdAtMs: 5_000, nowMs: 4_000) == 0)
}

@Test
func recallPresentItemKindLabelKeepsWireValues() {
    #expect(RecallPresent.itemKindLabel(.expanded) == "expanded")
    #expect(RecallPresent.itemKindLabel(.surrogate) == "surrogate")
    #expect(RecallPresent.itemKindLabel(.snippet) == "snippet")
}

@Test
func recallPresentCompactHitObjectOmitsFreshnessWhenTimestampUnknown() throws {
    let object = RecallPresent.compactHitObject(
        id: "durable:7",
        text: "plain",
        preview: nil,
        metadata: [:],
        score: 0.5,
        createdAtMs: 0,
        nowMs: 99
    )
    #expect(Set(object.keys) == ["id", "text", "score"])
    #expect(object["id"]?.stringValue == "durable:7")
    #expect(object["text"]?.stringValue == "plain")
    #expect(object["score"]?.doubleValue == 0.5)
    #expect(object["created_at_ms"] == nil)
    #expect(object["age_days"] == nil)
    #expect(object["preview"] == nil)
}

@Test
func recallPresentCompactHitObjectKeepsExactOptionalWireKeys() throws {
    let dayMs: Int64 = 1000 * 60 * 60 * 24
    let createdAtMs: Int64 = 1_000
    let nowMs = createdAtMs + (3 * dayMs)
    let object = RecallPresent.compactHitObject(
        id: "durable:9",
        text: "full text",
        preview: "preview text",
        metadata: [
            MemoryMetadataKeys.project: "Wax",
            MemoryMetadataKeys.repo: "wax",
            MemoryMetadataKeys.type: MemoryType.fact.rawValue,
            MemoryMetadataKeys.durability: MemoryDurability.durable.rawValue,
            MemoryMetadataKeys.reviewed: "true",
            MemoryMetadataKeys.confidence: "0.81",
        ],
        score: 0.91,
        createdAtMs: createdAtMs,
        nowMs: nowMs
    )
    #expect(Set(object.keys) == [
        "id", "text", "score", "created_at_ms", "age_days", "preview",
        "project", "repo", "memory_type", "durability", "reviewed", "confidence",
    ])
    #expect(object["created_at_ms"]?.intValue == createdAtMs)
    #expect(object["age_days"]?.intValue == 3)
    #expect(object["preview"]?.stringValue == "preview text")
    #expect(object["project"]?.stringValue == "Wax")
    #expect(object["repo"]?.stringValue == "wax")
    #expect(object["memory_type"]?.stringValue == "fact")
    #expect(object["durability"]?.stringValue == "durable")
    #expect(object["reviewed"]?.boolValue == true)
    #expect(object["confidence"]?.doubleValue == 0.81)
}

@Test
func recallPresentRenderRecallHitKeepsWireShape() throws {
    let sessionID = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
    let hit = LayeredRecall.Hit(
        id: .working(sessionID: sessionID, frameID: 42),
        score: 0.77,
        text: "working hit text",
        preview: "ignored preview",
        metadata: [
            MemoryMetadataKeys.project: "Wax",
            MemoryMetadataKeys.type: MemoryType.note.rawValue,
        ],
        explanations: ["why-a", "why-b"],
        timestampMs: 1_234,
        kind: .expanded,
        sources: [.text, .vector]
    )
    let nowMs: Int64 = 1_234 + (1000 * 60 * 60 * 24)
    let compact = try #require(
        RecallPresent.renderRecallHit(hit, rank: 3, verbose: false, nowMs: nowMs).objectValue
    )
    #expect(Set(compact.keys) == [
        "id", "text", "score", "created_at_ms", "age_days", "project", "memory_type",
        "rank", "kind", "frameId", "sources",
    ])
    #expect(compact["id"]?.stringValue == "working:\(sessionID.uuidString):42")
    #expect(compact["rank"]?.intValue == 3)
    #expect(compact["kind"]?.stringValue == "expanded")
    #expect(compact["frameId"]?.intValue == 42)
    #expect(compact["sources"]?.arrayValue?.compactMap(\.stringValue) == ["text", "vector"])
    #expect(compact["preview"] == nil)
    #expect(compact["metadata"] == nil)
    #expect(compact["explanations"] == nil)

    let verbose = try #require(
        RecallPresent.renderRecallHit(hit, rank: 3, verbose: true, nowMs: nowMs).objectValue
    )
    #expect(verbose["metadata"]?.objectValue?[MemoryMetadataKeys.project]?.stringValue == "Wax")
    #expect(verbose["explanations"]?.arrayValue?.compactMap(\.stringValue) == ["why-a", "why-b"])
}

@Test
func recallPresentRenderLayeredMemoryHitKeepsWireShape() throws {
    let sessionID = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!
    let hit = LayeredRecall.Hit(
        id: .episodic(sessionID: sessionID, frameID: 9),
        agentID: "agent-a",
        runID: "run-b",
        score: 0.4,
        text: "episodic text",
        preview: "episodic preview",
        metadata: [
            MemoryMetadataKeys.repo: "wax",
            MemoryMetadataKeys.durability: MemoryDurability.working.rawValue,
        ],
        explanations: ["lane"],
        timestampMs: 0
    )
    let rendered = try #require(
        RecallPresent.renderLayeredMemoryHit(hit, nowMs: 99).objectValue
    )
    #expect(Set(rendered.keys) == [
        "id", "text", "score", "preview", "repo", "durability",
        "memory_id", "horizon", "session_id", "agent_id", "run_id",
        "frame_id", "explanations", "metadata",
    ])
    #expect(rendered["age_days"] == nil)
    #expect(rendered["created_at_ms"] == nil)
    #expect(rendered["memory_id"]?.stringValue == hit.reference)
    #expect(rendered["horizon"]?.stringValue == "episodic")
    #expect(rendered["session_id"]?.stringValue == sessionID.uuidString)
    #expect(rendered["agent_id"]?.stringValue == "agent-a")
    #expect(rendered["run_id"]?.stringValue == "run-b")
    #expect(rendered["frame_id"]?.intValue == 9)
    #expect(rendered["explanations"]?.arrayValue?.compactMap(\.stringValue) == ["lane"])
    #expect(rendered["metadata"]?.objectValue?[MemoryMetadataKeys.repo]?.stringValue == "wax")
}

@Test
func recallPresentRenderCompactLayeredMemoryHitKeepsWireShape() throws {
    let hit = LayeredRecall.Hit(
        id: .durable(frameID: 77),
        score: 0.2,
        text: "durable text",
        preview: "durable preview",
        metadata: [MemoryMetadataKeys.project: "Wax"],
        explanations: ["ignored"],
        timestampMs: 5_000
    )
    let rendered = try #require(
        RecallPresent.renderCompactLayeredMemoryHit(hit, nowMs: 5_000).objectValue
    )
    #expect(Set(rendered.keys) == [
        "id", "text", "score", "created_at_ms", "age_days", "preview", "project",
        "memory_id", "frame_id",
    ])
    #expect(rendered["memory_id"]?.stringValue == "durable:77")
    #expect(rendered["frame_id"]?.intValue == 77)
    #expect(rendered["horizon"] == nil)
    #expect(rendered["session_id"] == nil)
    #expect(rendered["explanations"] == nil)
    #expect(rendered["metadata"] == nil)
}
