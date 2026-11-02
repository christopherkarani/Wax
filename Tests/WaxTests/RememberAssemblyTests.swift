import Foundation
import Testing
@testable import Wax

/// The newer text only adds "now", so it subsumes the original.
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
    project: String = "wax",
    supersededBy: UInt64? = nil
) -> RememberAssembly.Candidate {
    RememberAssembly.Candidate(
        frameId: frameId,
        text: text,
        metadata: durableMetadata(type: type, durability: durability, project: project, repo: project),
        supersededBy: supersededBy
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
        searchable: true,
        content: originalDecision
    )
    let object = try #require(payload.objectValue)
    #expect(Set(object.keys) == [
        "status", "committed", "frame_id", "memory_id", "framesAdded", "frameCount", "pendingFrames",
        "scope", "session_id", "memory_type", "durability", "deduplicated", "searchable",
        "echo", "echo_truncated", "content_sha8", "stored",
        "stored_truncated", "chunked", "chunk_count", "content_bytes",
        "unresolved_project", "display_text", "project", "repo",
    ])
    #expect(object["echo"]?.stringValue == originalDecision)
    #expect(object["stored"]?.stringValue == originalDecision)
    #expect(object["status"]?.stringValue == "ok")
    #expect(object["committed"]?.boolValue == true)
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
    #expect(object["echo_truncated"]?.boolValue == false)
    #expect(object["stored_truncated"]?.boolValue == false)
    #expect(object["content_sha8"]?.stringValue == "c676bad7")
    #expect(object["chunked"]?.boolValue == false)
    #expect(object["chunk_count"]?.intValue == 1)
    #expect(object["unresolved_project"]?.boolValue == false)
    #expect(object["project"]?.stringValue == "wax")
    #expect(object["repo"]?.stringValue == "wax")
    #expect(
        object["display_text"]?.stringValue
            == "Full content stored (72 bytes, sha c676bad7); echo shows first 240 chars."
    )
    #expect(object["next_action"] == nil)
}

@Test
func rememberAssemblyPayloadFlagsChunkedLargeWrites() throws {
    let content = String(repeating: "a", count: 300)
    let payload = RememberAssembly.payload(
        frameId: 1,
        framesAdded: 15,
        frameCount: 30,
        pendingFrames: 0,
        sessionID: nil,
        metadata: durableMetadata(),
        inferredScope: MemoryScopeContext(repoName: "wax", projectName: "wax"),
        deduplicated: false,
        searchable: true,
        content: content
    )
    let object = try #require(payload.objectValue)
    #expect(object["chunked"]?.boolValue == true)
    #expect(object["chunk_count"]?.intValue == 15)
    #expect(object["echo_truncated"]?.boolValue == true)
    #expect(object["stored_truncated"]?.boolValue == true)
    #expect(object["content_bytes"]?.intValue == Int64(content.utf8.count))
    #expect((object["display_text"]?.stringValue ?? "").contains("chunked into 15 frames"))
}

@Test
func rememberAssemblyPayloadEchoesStoredContent() throws {
    let content = "C01 GitLiveProbe stays intent until this tree has the type."
    let payload = RememberAssembly.payload(
        frameId: 42,
        framesAdded: 1,
        frameCount: 9,
        pendingFrames: 2,
        sessionID: nil,
        metadata: durableMetadata(),
        inferredScope: MemoryScopeContext(repoName: "wax", projectName: "wax"),
        deduplicated: false,
        searchable: true,
        content: content
    )
    let object = try #require(payload.objectValue)
    #expect(object["echo"]?.stringValue == content)
    #expect(object["stored"]?.stringValue == content)
    #expect(object["memory_id"]?.stringValue == "durable:42")
    #expect(object["committed"]?.boolValue == true)
    #expect(object["searchable"]?.boolValue == true)
}

@Test
func rememberAssemblyPayloadTruncatesStoredEchoAt240Characters() throws {
    let content = String(repeating: "a", count: 300)
    let payload = RememberAssembly.payload(
        frameId: 1,
        framesAdded: 1,
        frameCount: 1,
        pendingFrames: 0,
        sessionID: nil,
        metadata: durableMetadata(),
        inferredScope: MemoryScopeContext(repoName: "wax", projectName: "wax"),
        deduplicated: false,
        searchable: true,
        content: content
    )
    let echo = try #require(payload.objectValue?["echo"]?.stringValue)
    #expect(echo == String(repeating: "a", count: 240))
    #expect(echo.count == 240)
    #expect(payload.objectValue?["stored"]?.stringValue == echo)
}

@Test
func rememberAssemblyPayloadTruncationBoundaryIsExact() throws {
    for count in [240, 241] {
        let content = String(repeating: "b", count: count)
        let payload = RememberAssembly.payload(
            frameId: 1,
            framesAdded: 1,
            frameCount: 1,
            pendingFrames: 0,
            sessionID: nil,
            metadata: durableMetadata(),
            inferredScope: MemoryScopeContext(repoName: "wax", projectName: "wax"),
            deduplicated: false,
            searchable: true,
            content: content
        )
        let object = try #require(payload.objectValue)
        let expectedTruncated = count > RememberAssembly.storedEchoLimit
        #expect(object["echo_truncated"]?.boolValue == expectedTruncated)
        #expect(object["stored_truncated"]?.boolValue == expectedTruncated)
        #expect(object["echo"]?.stringValue?.count == min(count, RememberAssembly.storedEchoLimit))
    }
}

@Test
func rememberAssemblyPayloadHandlesZeroFramesAdded() throws {
    let content = "deduped"
    let payload = RememberAssembly.payload(
        frameId: 9,
        framesAdded: 0,
        frameCount: 9,
        pendingFrames: 0,
        sessionID: nil,
        metadata: durableMetadata(),
        inferredScope: MemoryScopeContext(repoName: "wax", projectName: "wax"),
        deduplicated: true,
        searchable: true,
        content: content
    )
    let object = try #require(payload.objectValue)
    #expect(object["chunked"]?.boolValue == false)
    #expect(object["chunk_count"]?.intValue == 0)
    #expect(object["echo_truncated"]?.boolValue == false)
    #expect(object["content_bytes"]?.intValue == Int64(content.utf8.count))
    #expect(object["content_sha8"]?.stringValue == "a18ba73f")
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
        searchable: false,
        content: originalDecision
    )
    let object = try #require(payload.objectValue)
    #expect(object["scope"]?.stringValue == "session")
    #expect(object["committed"]?.boolValue == true)
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
        searchable: true,
        content: originalDecision
    )
    let object = try #require(payload.objectValue)
    #expect(object["unresolved_project"]?.boolValue == true)
    #expect(object["project"] == nil)
    #expect(object["repo"] == nil)
    #expect(object["next_action"]?.stringValue == "pass project/repo or recall with scope=global")
    #expect(
        object["display_text"]?.stringValue
            == "Full content stored (72 bytes, sha c676bad7); echo shows first 240 chars. Project unresolved; default recall will miss this unless you pass project/repo or scope=global."
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
        searchable: true,
        content: originalDecision
    )
    let object = try #require(payload.objectValue)
    #expect(object["project"]?.stringValue == "from-cwd")
    #expect(object["repo"]?.stringValue == "from-repo")
    #expect(object["unresolved_project"]?.boolValue == false)
}

@Test
func rememberAssemblyPayloadEchoesBoundSessionOnDurableWrite() throws {
    let bound = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!
    let payload = RememberAssembly.payload(
        frameId: 42,
        framesAdded: 1,
        frameCount: 9,
        pendingFrames: 0,
        sessionID: nil,
        echoedSessionID: bound,
        metadata: durableMetadata(),
        inferredScope: MemoryScopeContext(repoName: "wax", projectName: "wax"),
        deduplicated: false,
        searchable: true,
        content: originalDecision
    )
    let object = try #require(payload.objectValue)
    #expect(object["scope"]?.stringValue == "durable")
    #expect(object["memory_id"]?.stringValue == "durable:42")
    #expect(object["committed"]?.boolValue == true)
    #expect(object["session_id"]?.stringValue == bound.uuidString)
}

@Test
func rememberAssemblyContentSHA8MatchesKnownDigests() {
    #expect(RememberAssembly.contentSHA8(for: originalDecision) == "c676bad7")
    #expect(RememberAssembly.contentSHA8(for: "deduped") == "a18ba73f")
    #expect(
        RememberAssembly.contentSHA8(for: "C01 GitLiveProbe stays intent until this tree has the type.")
            == "5dc5ef31"
    )
}

@Test
func rememberAssemblyCompactSlimKeepsMinimalKeys() throws {
    let payload = RememberAssembly.payload(
        frameId: 42,
        framesAdded: 1,
        frameCount: 9,
        pendingFrames: 2,
        sessionID: nil,
        metadata: durableMetadata(),
        inferredScope: MemoryScopeContext(repoName: "wax", projectName: "wax"),
        deduplicated: false,
        searchable: true,
        content: originalDecision
    )
    let object = try #require(payload.objectValue)
    let slim = RememberAssembly.slimCompactRememberPayload(object)
    #expect(Set(slim.keys) == [
        "status", "committed", "memory_id", "frame_id", "scope",
        "content_bytes", "content_sha8", "echo", "echo_truncated",
        "project", "repo",
    ])
    #expect(slim["echo"]?.stringValue == originalDecision)
    #expect(slim["echo_truncated"]?.boolValue == false)
    #expect(slim["content_sha8"]?.stringValue == "c676bad7")
    #expect(slim["content_bytes"]?.intValue == 72)
}

@Test
func rememberAssemblyCompactSlimDropsProjectWhenAbsent() throws {
    let payload = RememberAssembly.payload(
        frameId: 1,
        framesAdded: 1,
        frameCount: 1,
        pendingFrames: 0,
        sessionID: nil,
        metadata: durableMetadata(project: nil, repo: nil),
        inferredScope: MemoryScopeContext(),
        deduplicated: false,
        searchable: true,
        content: originalDecision
    )
    let object = try #require(payload.objectValue)
    let slim = RememberAssembly.slimCompactRememberPayload(object)
    #expect(slim["project"] == nil)
    #expect(slim["repo"] == nil)
    #expect(slim["status"]?.stringValue == "ok")
    #expect(slim["memory_id"]?.stringValue == "durable:1")
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
func rememberAssemblySkipsAlreadySupersededTwins() {
    let selected = RememberAssembly.selectSupersedeFrameIDs(
        sessionID: nil,
        newFrameId: 3,
        content: similarDecision,
        metadata: durableMetadata(),
        documents: [
            candidate(frameId: 1, text: originalDecision, supersededBy: 2),
            candidate(frameId: 4, text: originalDecision),
        ],
        nowMs: 0
    )
    #expect(selected == [4])
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

private let identifierHolesOriginal =
    "Remaining holes: C01 GitLiveProbe, C02 UniqueRanking, C03 CompactSummary. Do not re-propose."
/// Same identifiers; only adds words ("open", "them"), with text Jaccard under 0.88.
/// A looser rewording ("Do not re-run C01 ... this session.") shares the
/// identifiers but not the content, so it is intentionally not auto-superseded.
private let identifierHolesParaphrase =
    "Remaining open holes: C01 GitLiveProbe, C02 UniqueRanking, C03 CompactSummary. Do not re-propose them."
/// Two different lessons that name the same three types. Identifiers match,
/// but the shared vocabulary is low: neither restates the other.
private let lessonCallOrder =
    "Lesson: GitLiveProbe must call UniqueRanking before CompactSummary flushes."
private let lessonEmptyCrash =
    "Lesson: CompactSummary crashes when UniqueRanking returns empty; GitLiveProbe unaffected."

@Test
func rememberAssemblySelectsIdentifierOverlapBelowTextJaccard() {
    let similarity = MemorySemantics.similarity(lhs: identifierHolesOriginal, rhs: identifierHolesParaphrase)
    #expect(similarity < 0.88)
    #expect(
        MemorySemantics.contentSimilarity(lhs: identifierHolesOriginal, rhs: identifierHolesParaphrase)
            >= MemorySemantics.nearTwinContentSimilarityFloor
    )
    let selected = RememberAssembly.selectSupersedeFrameIDs(
        sessionID: nil,
        newFrameId: 2,
        content: identifierHolesParaphrase,
        metadata: durableMetadata(),
        documents: [candidate(frameId: 1, text: identifierHolesOriginal)],
        nowMs: 0
    )
    #expect(selected == [1])
}

@Test
func rememberAssemblyIdentifierOverlapStillRequiresSameType() {
    let selected = RememberAssembly.selectSupersedeFrameIDs(
        sessionID: nil,
        newFrameId: 2,
        content: identifierHolesParaphrase,
        metadata: durableMetadata(type: MemoryType.constraint.rawValue),
        documents: [
            candidate(frameId: 1, text: identifierHolesOriginal, type: MemoryType.fact.rawValue),
        ],
        nowMs: 0
    )
    #expect(selected.isEmpty)
}

@Test
func rememberAssemblyKeepsDistinctLessonsThatShareIdentifiers() {
    #expect(MemorySemantics.identifiersMatch(lessonCallOrder, lessonEmptyCrash))
    #expect(!MemorySemantics.isNearTwin(older: lessonCallOrder, newer: lessonEmptyCrash))
    let selected = RememberAssembly.selectSupersedeFrameIDs(
        sessionID: nil,
        newFrameId: 2,
        content: lessonEmptyCrash,
        metadata: durableMetadata(type: MemoryType.lesson.rawValue),
        documents: [candidate(frameId: 1, text: lessonCallOrder, type: MemoryType.lesson.rawValue)],
        nowMs: 0
    )
    #expect(selected.isEmpty)
}

@Test
func nearTwinRequiresVocabularyNotJustIdentifiers() {
    #expect(MemorySemantics.isNearTwin(older: originalDecision, newer: similarDecision))
    #expect(MemorySemantics.isNearTwin(older: identifierHolesOriginal, newer: identifierHolesParaphrase))
    #expect(!MemorySemantics.isNearTwin(older: lessonCallOrder, newer: lessonEmptyCrash))
    #expect(!MemorySemantics.isNearTwin(older: "old decision", newer: "new decision"))
}

@Test
func nearTwinRejectsSameIdentifiersWithDifferentAction() {
    let closeOrder = "Lesson: WaxSession, MemoryOrchestrator and VectorIndex must be closed in order before flush."
    let openLazily = "Lesson: WaxSession, MemoryOrchestrator and VectorIndex must be opened lazily before search."
    #expect(MemorySemantics.identifiersMatch(closeOrder, openLazily))
    #expect(!MemorySemantics.isNearTwin(older: closeOrder, newer: openLazily))
}

@Test
func nearTwinRejectsDifferentIssueNumbers() {
    let bug123 = "Bug #123 in WaxSession: MemoryOrchestrator crashes on flush."
    let bug124 = "Bug #124 in WaxSession: MemoryOrchestrator crashes on open."
    #expect(!MemorySemantics.isNearTwin(older: bug123, newer: bug124))
    // The pure-text path is guarded too: identical wording, different ticket.
    #expect(!MemorySemantics.isNearTwin(
        older: "Bug #123 in WaxSession: MemoryOrchestrator crashes on flush after compaction.",
        newer: "Bug #124 in WaxSession: MemoryOrchestrator crashes on flush after compaction."
    ))
}

@Test
func nearTwinRejectsNegationFlip() {
    let use = "Use GitLiveProbe for UniqueRanking in CompactSummary."
    let neverUse = "Never use GitLiveProbe outside UniqueRanking or CompactSummary."
    #expect(!MemorySemantics.isNearTwin(older: use, newer: neverUse))
    #expect(!MemorySemantics.isNearTwin(
        older: "Prefer project-scoped recall and auto-widen an empty project lane.",
        newer: "Prefer project-scoped recall and never auto-widen an empty project lane."
    ))
}

@Test
func supersedeCandidateGateFiltersOnMetadataOnly() {
    let lesson = MemoryType.lesson
    #expect(
        RememberAssembly.isSupersedeCandidate(
            metadata: durableMetadata(type: lesson.rawValue),
            supersededBy: nil, type: lesson, project: "wax", nowMs: 0
        )
    )
    #expect(
        !RememberAssembly.isSupersedeCandidate(
            metadata: durableMetadata(type: lesson.rawValue),
            supersededBy: 9, type: lesson, project: "wax", nowMs: 0
        )
    )
    #expect(
        !RememberAssembly.isSupersedeCandidate(
            metadata: durableMetadata(type: MemoryType.fact.rawValue),
            supersededBy: nil, type: lesson, project: "wax", nowMs: 0
        )
    )
    #expect(
        !RememberAssembly.isSupersedeCandidate(
            metadata: durableMetadata(type: lesson.rawValue, project: "other"),
            supersededBy: nil, type: lesson, project: "wax", nowMs: 0
        )
    )
    #expect(
        !RememberAssembly.isSupersedeCandidate(
            metadata: durableMetadata(type: lesson.rawValue, durability: MemoryDurability.locked.rawValue),
            supersededBy: nil, type: lesson, project: "wax", nowMs: 0
        )
    )
}

/// True when writing `newer` auto-supersedes an existing durable `older` of the same type.
private func supersedes(older: String, newer: String, type: MemoryType = .decision) -> Bool {
    !RememberAssembly.selectSupersedeFrameIDs(
        sessionID: nil,
        newFrameId: 2,
        content: newer,
        metadata: durableMetadata(type: type.rawValue),
        documents: [candidate(frameId: 1, text: older, type: type.rawValue)],
        nowMs: 0
    ).isEmpty
}

@Test
func supersedeAllowsNewerTextToAddAPreciseReference() {
    let withRef = originalDecision + " (#212)"
    #expect(supersedes(older: originalDecision, newer: withRef))
    // Dropping the reference loses information: the referenced memory stays live.
    #expect(!supersedes(older: withRef, newer: originalDecision))
}

private let broadFlushLesson =
    "Lesson: GitLiveProbe, UniqueRanking, CompactSummary, WalRing and VectorIndex flush ordering matters for crash recovery and replay."
private let narrowFlushLesson = "Lesson: GitLiveProbe, UniqueRanking, CompactSummary flush ordering matters."

@Test
func supersedeNeverRetiresABroaderOlderMemory() {
    #expect(!supersedes(older: broadFlushLesson, newer: narrowFlushLesson, type: .lesson))
    #expect(supersedes(older: narrowFlushLesson, newer: broadFlushLesson, type: .lesson))
}

@Test
func staleHintIsDirectionalForBroaderOlderMemory() {
    let flags = StaleHint.flags(for: [
        StaleHint.Entry(memoryType: "lesson", createdAtMs: 1_000, text: broadFlushLesson),
        StaleHint.Entry(memoryType: "lesson", createdAtMs: 2_000, text: narrowFlushLesson),
    ])
    #expect(flags == [false, false])
}

@Test
func supersedeIgnoresIncidentalNegationTokens() {
    #expect(supersedes(
        older: "FlushPolicy batches WAL writes and fsyncs once per batch.",
        newer: "FlushPolicy batches WAL writes and fsyncs once per batch; no-op when empty."
    ))
    #expect(supersedes(
        older: "VectorIndex rebuilds run in the background after compaction.",
        newer: "VectorIndex rebuilds run in the background after compaction without blocking recall."
    ))
    #expect(supersedes(
        older: "VectorIndex rebuilds cut tail latency after compaction.",
        newer: "VectorIndex rebuilds not only cut tail latency after compaction."
    ))
    // A real polarity flip still blocks.
    #expect(!supersedes(
        older: "Prefer project-scoped recall and auto-widen an empty project lane.",
        newer: "Prefer project-scoped recall and never auto-widen an empty project lane."
    ))
}

@Test
func supersedeMatchesRewordingWithoutIdentifiers() {
    #expect(supersedes(
        older: "We should always run the linter before commit.",
        newer: "Always run the linter before you commit."
    ))
    #expect(!supersedes(older: "old decision", newer: "new decision"))
}

@Test
func supersedeAllowsNewerTextToAddAnIdentifierToAnIdentifierFreeMemory() {
    #expect(supersedes(
        older: "Always run the linter before commit.",
        newer: "Always run the linter before commit in WaxSession."
    ))
}

@Test
func supersedeNeverRetiresAMemoryWhoseContentTermWasSubstituted() {
    // Sharing a type name must not make a different fact a restatement.
    #expect(!supersedes(
        older: "MemoryOrchestrator: flush latency p99 under 5 ms on macOS.",
        newer: "MemoryOrchestrator: flush latency p99 under 5 ms on Linux."
    ))
    #expect(!supersedes(
        older: "MemoryOrchestrator: cache embeddings in memory for hybrid search.",
        newer: "MemoryOrchestrator: evict embeddings from memory for hybrid search."
    ))
    #expect(!supersedes(
        older: "VectorIndex benchmark: hybrid recall p50 is 12 ms with 10k documents in the corpus.",
        newer: "VectorIndex benchmark: hybrid recall p50 is 12 ms with 100k documents in the corpus."
    ))
}

@Test
func supersedeTreatsContractedNegationAsNegation() {
    #expect(!supersedes(
        older: "WaxSession can't be shared across actors.",
        newer: "WaxSession can be shared across actors."
    ))
    #expect(!supersedes(
        older: "WaxSession can be shared across actors.",
        newer: "WaxSession can\u{2019}t be shared across actors."
    ))
    #expect(!supersedes(
        older: "The broker should retry a failed embed.",
        newer: "The broker shouldn't retry a failed embed."
    ))
    // The same negation spelled two ways is still the same memory.
    #expect(supersedes(
        older: "WaxSession can't be shared across actors.",
        newer: "WaxSession cannot be shared across actors."
    ))
    #expect(supersedes(
        older: "The broker won't retry a failed embed.",
        newer: "The broker will not retry a failed embed."
    ))
}

@Test
func identifierExtractionKeepsMultiPartTicketKeysWhole() {
    #expect(MemorySemantics.extractIdentifiers("Patched CVE-2024-1234 today.") == ["cve-2024-1234"])
}

@Test
func supersedeNeverLetsALongMemorySwallowAShortOne() {
    #expect(!supersedes(
        older: "Run the linter.",
        newer: "Run the linter, then the formatter, the type checker, the unit tests and the integration suite before release."
    ))
}

@Test
func identifierExtractionSkipsCommonTokensDatesAndPlainNumbers() {
    let ids = MemorySemantics.extractIdentifiers(
        "UTF8 on S3 with H264, P1 since 20261102, run 1234567; A1 L2 GPT4 ARM64 SHA256 MD5 X86 V2 R2 C4 "
            + "ISO-8601 UTF-8 AES-256 SHA-256"
    )
    #expect(ids.isEmpty, "\(ids)")
    let kept = MemorySemantics.extractIdentifiers("C01 on T1, PROJ-42, sha 466c1e6")
    #expect(kept == ["c01", "t1", "proj-42", "466c1e6"])
}
