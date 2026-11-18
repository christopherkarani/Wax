import Foundation
import WaxCore

extension VirtualSessionStore {
    package struct SessionState: Sendable {
        package let id: UUID
        package var manifest: BrokerSessionManifest
        package let manifestURL: URL
        package let eventLogURL: URL
        package let storeURL: URL
        package let memory: MemoryOrchestrator
    }

    package enum LifecycleResult: Sendable {
        case started(SessionState)
        case resumed(SessionState, recoveredLease: Bool)

        package var state: SessionState {
            switch self {
            case .started(let state), .resumed(let state, _):
                return state
            }
        }

        package var resumed: Bool {
            switch self {
            case .started:
                return false
            case .resumed:
                return true
            }
        }

        package var recoveredLease: Bool {
            switch self {
            case .started:
                return false
            case .resumed(_, let recoveredLease):
                return recoveredLease
            }
        }
    }

    package enum EndResult: Sendable {
        case idle
        case ended(sessionID: UUID, remainingActive: Int, harvest: SessionHarvest.Report)

        package var sessionID: UUID? {
            switch self {
            case .idle:
                return nil
            case .ended(let sessionID, _, _):
                return sessionID
            }
        }

        package var ended: Bool {
            switch self {
            case .idle:
                return false
            case .ended:
                return true
            }
        }

        package var remainingActive: Bool {
            activeCount > 0
        }

        package var activeCount: Int {
            switch self {
            case .idle:
                return 0
            case .ended(_, let remainingActive, _):
                return remainingActive
            }
        }

        package var harvest: SessionHarvest.Report {
            switch self {
            case .idle:
                return .skipped
            case .ended(_, _, let harvest):
                return harvest
            }
        }
    }

    package enum Lookup: Sendable {
        /// No virtual session. Caller uses long-term Memory.
        case none
        case live(MemoryOrchestrator)
    }
}
