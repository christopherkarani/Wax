import Foundation
import Testing
@testable import Wax

struct SessionOpenDecisionTests {
    private let matchA = SessionOpenDecision.Match(
        sessionID: UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!,
        runID: "run-a"
    )
    private let hintedID = UUID(uuidString: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB")!

    @Test
    func evaluateResumesConversationMatch() {
        let facts = SessionOpenDecision.Facts(
            conversationID: "conv-1",
            conversationMatch: matchA,
            hintedSessionID: hintedID,
            hintedResumable: true,
            priorUnique: nil,
            requestedRunID: "run-b"
        )

        #expect(SessionOpenDecision.evaluate(facts) == .resume(sessionID: matchA.sessionID))
    }

    @Test
    func evaluateStartsNewWhenConversationHasNoMatchEvenIfHintedResumable() {
        let facts = SessionOpenDecision.Facts(
            conversationID: "conv-1",
            conversationMatch: nil,
            hintedSessionID: hintedID,
            hintedResumable: true,
            priorUnique: nil,
            requestedRunID: nil
        )

        #expect(SessionOpenDecision.evaluate(facts) == .startNew)
    }

    @Test
    func evaluateResumesHintedWhenNoConversation() {
        let facts = SessionOpenDecision.Facts(
            conversationID: nil,
            conversationMatch: nil,
            hintedSessionID: hintedID,
            hintedResumable: true,
            priorUnique: nil,
            requestedRunID: nil
        )

        #expect(SessionOpenDecision.evaluate(facts) == .resume(sessionID: hintedID))
    }

    @Test
    func evaluateStartsNewWhenNoConversationAndHintNotResumable() {
        let facts = SessionOpenDecision.Facts(
            conversationID: nil,
            conversationMatch: nil,
            hintedSessionID: hintedID,
            hintedResumable: false,
            priorUnique: nil,
            requestedRunID: nil
        )

        #expect(SessionOpenDecision.evaluate(facts) == .startNew)
    }

    @Test
    func evaluateStartsNewWhenNoConversationAndNoHint() {
        let facts = SessionOpenDecision.Facts(
            conversationID: nil,
            conversationMatch: nil,
            hintedSessionID: nil,
            hintedResumable: true,
            priorUnique: nil,
            requestedRunID: nil
        )

        #expect(SessionOpenDecision.evaluate(facts) == .startNew)
    }

    @Test
    func evaluateStartsNewWhenPriorUniqueAlone() {
        // Unique rebind is owned by virtualSessions.start, not evaluate.
        let facts = SessionOpenDecision.Facts(
            conversationID: nil,
            conversationMatch: nil,
            hintedSessionID: nil,
            hintedResumable: false,
            priorUnique: matchA,
            requestedRunID: "run-b"
        )

        #expect(SessionOpenDecision.evaluate(facts) == .startNew)
    }

    @Test(arguments: [
        (
            "conversation match wins over hint",
            SessionOpenDecision.Facts(
                conversationID: "c",
                conversationMatch: SessionOpenDecision.Match(
                    sessionID: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!,
                    runID: "r1"
                ),
                hintedSessionID: UUID(uuidString: "22222222-2222-2222-2222-222222222222")!,
                hintedResumable: true,
                priorUnique: nil,
                requestedRunID: nil
            ),
            SessionOpenDecision.Action.resume(
                sessionID: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
            )
        ),
        (
            "conversation miss isolates from hint",
            SessionOpenDecision.Facts(
                conversationID: "c",
                conversationMatch: nil,
                hintedSessionID: UUID(uuidString: "22222222-2222-2222-2222-222222222222")!,
                hintedResumable: true,
                priorUnique: SessionOpenDecision.Match(
                    sessionID: UUID(uuidString: "33333333-3333-3333-3333-333333333333")!,
                    runID: "old"
                ),
                requestedRunID: "new"
            ),
            SessionOpenDecision.Action.startNew
        ),
        (
            "hint resume",
            SessionOpenDecision.Facts(
                conversationID: nil,
                conversationMatch: nil,
                hintedSessionID: UUID(uuidString: "22222222-2222-2222-2222-222222222222")!,
                hintedResumable: true,
                priorUnique: nil,
                requestedRunID: nil
            ),
            SessionOpenDecision.Action.resume(
                sessionID: UUID(uuidString: "22222222-2222-2222-2222-222222222222")!
            )
        ),
        (
            "priorUnique alone is startNew",
            SessionOpenDecision.Facts(
                conversationID: nil,
                conversationMatch: nil,
                hintedSessionID: nil,
                hintedResumable: false,
                priorUnique: SessionOpenDecision.Match(
                    sessionID: UUID(uuidString: "33333333-3333-3333-3333-333333333333")!,
                    runID: "old"
                ),
                requestedRunID: "new"
            ),
            SessionOpenDecision.Action.startNew
        ),
        (
            "default start",
            SessionOpenDecision.Facts(
                conversationID: nil,
                conversationMatch: nil,
                hintedSessionID: nil,
                hintedResumable: false,
                priorUnique: nil,
                requestedRunID: nil
            ),
            SessionOpenDecision.Action.startNew
        ),
    ])
    func evaluateTable(
        _ label: String,
        facts: SessionOpenDecision.Facts,
        expected: SessionOpenDecision.Action
    ) {
        #expect(SessionOpenDecision.evaluate(facts) == expected, "\(label)")
    }

    @Test
    func reboundTrueForPriorUniqueWithDifferentRunID() {
        let facts = SessionOpenDecision.Facts(
            conversationID: nil,
            conversationMatch: nil,
            hintedSessionID: nil,
            hintedResumable: false,
            priorUnique: matchA,
            requestedRunID: "run-b"
        )

        #expect(SessionOpenDecision.rebound(returnedSessionID: matchA.sessionID, facts: facts))
    }

    @Test
    func reboundTrueForPriorUniqueWithOmittedRunID() {
        let facts = SessionOpenDecision.Facts(
            conversationID: nil,
            conversationMatch: nil,
            hintedSessionID: nil,
            hintedResumable: false,
            priorUnique: matchA,
            requestedRunID: nil
        )

        #expect(SessionOpenDecision.rebound(returnedSessionID: matchA.sessionID, facts: facts))
    }

    @Test
    func reboundFalseForPriorUniqueWithSameRunID() {
        let facts = SessionOpenDecision.Facts(
            conversationID: nil,
            conversationMatch: nil,
            hintedSessionID: nil,
            hintedResumable: false,
            priorUnique: matchA,
            requestedRunID: matchA.runID
        )

        #expect(!SessionOpenDecision.rebound(returnedSessionID: matchA.sessionID, facts: facts))
    }

    @Test
    func reboundTrueForConversationResumeWithDifferentRunID() {
        let facts = SessionOpenDecision.Facts(
            conversationID: "conv-1",
            conversationMatch: matchA,
            hintedSessionID: nil,
            hintedResumable: false,
            priorUnique: nil,
            requestedRunID: "run-b"
        )

        #expect(SessionOpenDecision.rebound(returnedSessionID: matchA.sessionID, facts: facts))
    }

    @Test
    func reboundFalseWhenReturnedSessionDoesNotMatch() {
        let facts = SessionOpenDecision.Facts(
            conversationID: nil,
            conversationMatch: nil,
            hintedSessionID: hintedID,
            hintedResumable: true,
            priorUnique: matchA,
            requestedRunID: "run-b"
        )

        #expect(!SessionOpenDecision.rebound(returnedSessionID: hintedID, facts: facts))
    }
}
