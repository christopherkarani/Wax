import Foundation

/// Closed identity of a recall/get hit: durable frame, or working/episodic frame in a session.
package enum MemoryID: Hashable, Sendable {
    case durable(frameID: UInt64)
    case working(sessionID: UUID, frameID: UInt64)
    case episodic(sessionID: UUID, frameID: UInt64)

    package var horizon: LayeredRecall.Horizon {
        switch self {
        case .durable:
            return .durable
        case .working:
            return .working
        case .episodic:
            return .episodic
        }
    }

    package var sessionID: UUID? {
        switch self {
        case .durable:
            return nil
        case .working(let sessionID, _), .episodic(let sessionID, _):
            return sessionID
        }
    }

    package var frameID: UInt64 {
        switch self {
        case .durable(let frameID), .working(_, let frameID), .episodic(_, let frameID):
            return frameID
        }
    }

    package var wire: String {
        switch self {
        case .durable(let frameID):
            return "durable:\(frameID)"
        case .working(let sessionID, let frameID):
            return "working:\(sessionID.uuidString):\(frameID)"
        case .episodic(let sessionID, let frameID):
            return "episodic:\(sessionID.uuidString):\(frameID)"
        }
    }

    package func replacingFrameID(_ frameID: UInt64) -> MemoryID {
        switch self {
        case .durable:
            return .durable(frameID: frameID)
        case .working(let sessionID, _):
            return .working(sessionID: sessionID, frameID: frameID)
        case .episodic(let sessionID, _):
            return .episodic(sessionID: sessionID, frameID: frameID)
        }
    }

    package static func make(
        horizon: LayeredRecall.Horizon,
        sessionID: UUID,
        frameID: UInt64
    ) -> MemoryID {
        switch horizon {
        case .durable:
            return .durable(frameID: frameID)
        case .working:
            return .working(sessionID: sessionID, frameID: frameID)
        case .episodic:
            return .episodic(sessionID: sessionID, frameID: frameID)
        }
    }

    package static func parse(_ raw: String) throws -> MemoryID {
        let parts = raw.split(separator: ":").map(String.init)
        guard parts.count >= 2 else {
            throw BrokerValidationError.invalid(
                "memory_id must be in the form '<horizon>:<frame>' or '<horizon>:<session_id>:<frame>'"
            )
        }
        guard let horizon = LayeredRecall.Horizon(rawValue: parts[0]) else {
            throw BrokerValidationError.invalid("memory_id horizon must be one of: working, episodic, durable")
        }
        switch horizon {
        case .durable:
            guard parts.count == 2, let frameID = UInt64(parts[1]) else {
                throw BrokerValidationError.invalid("durable memory_id must be 'durable:<frame_id>'")
            }
            return .durable(frameID: frameID)
        case .working, .episodic:
            guard parts.count == 3,
                  let sessionID = UUID(uuidString: parts[1]),
                  let frameID = UInt64(parts[2])
            else {
                throw BrokerValidationError.invalid(
                    "session memory_id must be '\(horizon.rawValue):<session_id>:<frame_id>'"
                )
            }
            return make(horizon: horizon, sessionID: sessionID, frameID: frameID)
        }
    }
}
