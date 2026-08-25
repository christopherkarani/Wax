import Foundation
import Testing
@testable import Wax

/// Pins HorizonSet lane visibility after session-scope resolution to the exact
/// Bool-table behavior that preceded HorizonSet: a resolved session keeps the
/// request, durableOnly forces the durable lane, unscoped drops working.
struct HorizonScopeSelectionTests {
    private static let allRequests: [HorizonSet] = [
        [],
        [.working],
        [.episodic],
        [.durable],
        [.working, .episodic],
        [.working, .durable],
        [.episodic, .durable],
        HorizonSet.all,
    ]

    @Test
    func sessionScopeKeepsRequestedLanes() {
        let resolved = AgentBrokerService.ResolvedSessionScope.session(
            UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!
        )
        for requested in Self.allRequests {
            #expect(
                AgentBrokerService.scopedHorizons(scope: resolved, requested: requested) == requested,
                "session scope must keep \(requested.rawValue)"
            )
        }
    }

    @Test
    func unscopedScopeDropsWorkingLaneOnly() {
        for requested in Self.allRequests {
            #expect(
                AgentBrokerService.scopedHorizons(scope: .none, requested: requested) == requested.subtracting(.working),
                "unscoped scope must drop only working from \(requested.rawValue)"
            )
        }
    }

    @Test
    func durableOnlyScopeSelectsDurableLane() {
        for requested in Self.allRequests {
            #expect(
                AgentBrokerService.scopedHorizons(scope: .durableOnly, requested: requested) == [.durable],
                "durableOnly scope must select durable over \(requested.rawValue)"
            )
        }
    }

    @Test
    func laneMembershipMirrorsHorizonVocabulary() {
        #expect(HorizonSet.working.contains(.working))
        #expect(HorizonSet.episodic.contains(.episodic))
        #expect(HorizonSet.durable.contains(.durable))
        #expect(HorizonSet.working.intersection([.episodic, .durable]).isEmpty)
        #expect(HorizonSet.all.subtracting([.working, .episodic, .durable]).isEmpty)
    }
}
