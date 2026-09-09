import Foundation
import Testing
@testable import Wax

/// 11/12 Jaccard on `MemorySemantics.similarity` (threshold is 0.88).
private let originalDecision = "Prefer project-scoped recall and never auto-widen an empty project lane."
private let similarDecision = "Prefer project-scoped recall and never auto-widen an empty project lane now."

private func durableMetadata(
    type: String = MemoryType.decision.rawValue,
    durability: String = MemoryDurability.durable.rawValue,
    project: String? = "wax",
    repo: String? = "wax"
) -> [String: String] {
    var metadata: [String: String] = [
        MemoryMetadataKeys.type: type,
        MemoryMetadataKeys.durability: durability,
    ]
    if let project {
        metadata[MemoryMetadataKeys.project] = project
    }
    if let repo {
        metadata[MemoryMetadataKeys.repo] = repo
    }
    return metadata
}

private func candidate(
    frameId: UInt64,
    text: String,
    type: String = MemoryType.decision.rawValue,
    durability: String = MemoryDurability.durable.rawValue,
    project: String = "wax"
) -> RememberAssembly.Candidate {
    RememberAssembly.Candidate(
        frameId: frameId,
        text: text,
        metadata: durableMetadata(type: type, durability: durability, project: project, repo: project)
    )
}

@Test
func rememberAssemblyPayloadKeepsDurableWireShape() throws {
    let payload = RememberAssembly.payload(
        frameId: 42,
        framesAdded: 1,
        frameCount: 9,
        pendingFrames: 2,
        sessionID: nil,
        metadata: durableMetadata(),
        inferredScope: MemoryScopeContext(repoName: "inferred", projectName: "inferred"),
        deduplicated: false,
        searchable: true
    )
    let object = try #require(payload.objectValue)
    #expect(Set(object.keys) == [
        "status", "frame_id", "memory_id", "framesAdded", "frameCount", "pendingFrames",
        "scope", "session_id", "memory_type", "durability", "deduplicated", "searchable",
        "unresolved_project", "display_text", "project", "repo",
    ])
    #expect(object["status"]?.stringValue == "ok")
    #expect(object["frame_id"]?.intValue == 42)
    #expect(object["memory_id"]?.stringValue == "durable:42")
    #expect(object["framesAdded"]?.intValue == 1)
    #expect(object["frameCount"]?.intValue == 9)
    #expect(object["pendingFrames"]?.intValue == 2)
    #expect(object["scope"]?.stringValue == "durable")
    #expect(object["session_id"] == AgentBrokerValue.null)
    #expect(object["memory_type"]?.stringValue == "decision")
    #expect(object["durability"]?.stringValue == "durable")
    #expect(object["deduplicated"]?.boolValue == false)
    #expect(object["searchable"]?.boolValue == true)
    #expect(object["unresolved_project"]?.boolValue == false)
    #expect(object["project"]?.stringValue == "wax")
    #expect(object["repo"]?.stringValue == "wax")
    #expect(object["display_text"]?.stringValue == "Remembered. 1 frame(s) added (9 total, 2 pending).")
    #expect(object["next_action"] == nil)
}

@Test
func rememberAssemblyPayloadUsesWorkingMemoryIDForSession() throws {
    let sessionID = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!
    let payload = RememberAssembly.payload(
        frameId: 7,
        framesAdded: 1,
        frameCount: 3,
        pendingFrames: 0,
        sessionID: sessionID,
        metadata: durableMetadata(type: MemoryType.note.rawValue, durability: MemoryDurability.working.rawValue),
        inferredScope: MemoryScopeContext(),
        deduplicated: true,
        searchable: false
    )
    let object = try #require(payload.objectValue)
    #expect(object["scope"]?.stringValue == "session")
    #expect(object["session_id"]?.stringValue == sessionID.uuidString)
    #expect(object["memory_id"]?.stringValue == "working:\(sessionID.uuidString):7")
    #expect(object["memory_type"]?.stringValue == "note")
    #expect(object["durability"]?.stringValue == "working")
    #expect(object["deduplicated"]?.boolValue == true)
    #expect(object["searchable"]?.boolValue == false)
}

@Test
func rememberAssemblyPayloadMarksUnresolvedProjectAndNextAction() throws {
    let payload = RememberAssembly.payload(
        frameId: 1,
        framesAdded: 1,
        frameCount: 1,
        pendingFrames: 0,
        sessionID: nil,
        metadata: durableMetadata(project: nil, repo: nil),
        inferredScope: MemoryScopeContext(),
        deduplicated: false,
        searchable: true
    )
    let object = try #require(payload.objectValue)
    #expect(object["unresolved_project"]?.boolValue == true)
    #expect(object["project"] == nil)
    #expect(object["repo"] == nil)
    #expect(object["next_action"]?.stringValue == "pass project/repo or recall with scope=global")
    #expect(
        object["display_text"]?.stringValue
            == "Remembered. 1 frame(s) added (1 total, 0 pending). Project unresolved; default recall will miss this unless you pass project/repo or scope=global."
    )
}

@Test
func rememberAssemblyPayloadFallsBackToInferredScope() throws {
    let payload = RememberAssembly.payload(
        frameId: 5,
        framesAdded: 1,
        frameCount: 5,
        pendingFrames: 1,
        sessionID: nil,
        metadata: [
            MemoryMetadataKeys.type: MemoryType.fact.rawValue,
            MemoryMetadataKeys.durability: MemoryDurability.durable.rawValue,
        ],
        inferredScope: MemoryScopeContext(repoName: "from-repo", projectName: "from-cwd"),
        deduplicated: false,
        searchable: true
    )
    let object = try #require(payload.objectValue)
    #expect(object["project"]?.stringValue == "from-cwd")
    #expect(object["repo"]?.stringValue == "from-repo")
    #expect(object["unresolved_project"]?.boolValue == false)
}

@Test
func rememberAssemblySelectsSimilarSameProjectDurableTwin() {
    let selected = RememberAssembly.selectSupersedeFrameIDs(
        sessionID: nil,
        newFrameId: 2,
        content: similarDecision,
        metadata: durableMetadata(),
        documents: [
            candidate(frameId: 1, text: originalDecision),
            candidate(frameId: 2, text: similarDecision),
        ],
        nowMs: 0
    )
    #expect(selected == [1])
}

@Test
func rememberAssemblySkipsSupersedeWhenSessionPresent() {
    #expect(
        RememberAssembly.isAutoSupersedeEligible(
            sessionID: UUID(),
            metadata: durableMetadata(),
            nowMs: 0
        ) == false
    )
    let selected = RememberAssembly.selectSupersedeFrameIDs(
        sessionID: UUID(),
        newFrameId: 2,
        content: similarDecision,
        metadata: durableMetadata(),
        documents: [candidate(frameId: 1, text: originalDecision)],
        nowMs: 0
    )
    #expect(selected.isEmpty)
}

@Test
func rememberAssemblySkipsNonPolicyMemoryTypes() {
    let selected = RememberAssembly.selectSupersedeFrameIDs(
        sessionID: nil,
        newFrameId: 2,
        content: similarDecision,
        metadata: durableMetadata(type: MemoryType.note.rawValue),
        documents: [
            candidate(frameId: 1, text: originalDecision, type: MemoryType.note.rawValue),
        ],
        nowMs: 0
    )
    #expect(selected.isEmpty)
}

@Test
func rememberAssemblyRequiresSameProjectAndDurableOther() {
    let crossProject = RememberAssembly.selectSupersedeFrameIDs(
        sessionID: nil,
        newFrameId: 2,
        content: similarDecision,
        metadata: durableMetadata(project: "alpha", repo: "alpha"),
        documents: [candidate(frameId: 1, text: originalDecision, project: "beta")],
        nowMs: 0
    )
    #expect(crossProject.isEmpty)

    let lockedOther = RememberAssembly.selectSupersedeFrameIDs(
        sessionID: nil,
        newFrameId: 2,
        content: similarDecision,
        metadata: durableMetadata(),
        documents: [
            candidate(
                frameId: 1,
                text: originalDecision,
                durability: MemoryDurability.locked.rawValue
            ),
        ],
        nowMs: 0
    )
    #expect(lockedOther.isEmpty)
}

@Test
func rememberAssemblyLockedNewStillSelectsDurableOther() {
    let selected = RememberAssembly.selectSupersedeFrameIDs(
        sessionID: nil,
        newFrameId: 2,
        content: similarDecision,
        metadata: durableMetadata(durability: MemoryDurability.locked.rawValue),
        documents: [candidate(frameId: 1, text: originalDecision)],
        nowMs: 0
    )
    #expect(selected == [1])
}

@Test
func rememberAssemblyCapsSupersedeMatchesAt32() {
    let documents = (1...40).map { index in
        candidate(frameId: UInt64(index), text: originalDecision)
    }
    let selected = RememberAssembly.selectSupersedeFrameIDs(
        sessionID: nil,
        newFrameId: 99,
        content: similarDecision,
        metadata: durableMetadata(),
        documents: documents,
        nowMs: 0
    )
    #expect(selected.count == RememberAssembly.autoSupersedeMaxMatches)
    #expect(selected == Array(1...32).map(UInt64.init))
}
