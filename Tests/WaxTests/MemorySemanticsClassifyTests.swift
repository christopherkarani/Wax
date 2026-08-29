import Testing
@testable import Wax

@Suite("Memory semantics classify")
struct MemorySemanticsClassifyTests {
    @Test
    func implicitNoteWithDecisionPrefixClassifiesAsDecision() {
        #expect(
            MemorySemantics.classifyCandidate(
                text: "Decision: keep session notes promotable.",
                metadata: [MemoryMetadataKeys.type: MemoryType.note.rawValue]
            ) == .decision
        )
    }

    @Test
    func implicitNoteWithoutCueStaysNote() {
        #expect(
            MemorySemantics.classifyCandidate(
                text: "scratch reminder about the build.",
                metadata: [MemoryMetadataKeys.type: MemoryType.note.rawValue]
            ) == .note
        )
    }

    @Test
    func taskStateWithDecisionPrefixStillClassifiesAsDecision() {
        #expect(
            MemorySemantics.classifyCandidate(
                text: "Decision: promote this diary.",
                metadata: [MemoryMetadataKeys.type: MemoryType.taskState.rawValue]
            ) == .decision
        )
    }

    @Test
    func explicitDecisionTypeIsTrustedEvenWithoutCue() {
        #expect(
            MemorySemantics.classifyCandidate(
                text: "not a decision at all",
                metadata: [MemoryMetadataKeys.type: MemoryType.decision.rawValue]
            ) == .decision
        )
    }
}
