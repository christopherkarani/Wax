import Foundation

/// Client-facing composite memory identifier (the broker wire `memory_id`).
///
/// Wire grammar: durable frames never carry a session and render as
/// `durable:<frame>`; working/episodic frames render as
/// `<horizon>:<session-uuid>:<frame>`, where a missing session renders as the
/// literal `unknown`. The encoding is bijective: `unknown` parses back to a
/// nil session.
package struct MemoryReference: Sendable, Hashable {
    package let horizon: LayeredRecall.Horizon
    package let sessionID: UUID?
    package let frameID: UInt64

    package init?(horizon: LayeredRecall.Horizon, sessionID: UUID?, frameID: UInt64) {
        guard horizon != .durable || sessionID == nil else { return nil }
        self.horizon = horizon
        self.sessionID = sessionID
        self.frameID = frameID
    }

    package init?(parsing raw: String) {
        let parts = raw.split(separator: ":").map(String.init)
        guard parts.count >= 2, let horizon = LayeredRecall.Horizon(rawValue: parts[0]) else {
            return nil
        }
        switch horizon {
        case .durable:
            guard parts.count == 2, let parsedFrameID = UInt64(parts[1]) else { return nil }
            self.horizon = .durable
            self.sessionID = nil
            self.frameID = parsedFrameID
        case .working, .episodic:
            guard parts.count == 3, let frameID = UInt64(parts[2]) else {
                return nil
            }
            let sessionID: UUID?
            if parts[1] == "unknown" {
                sessionID = nil
            } else if let parsed = UUID(uuidString: parts[1]) {
                sessionID = parsed
            } else {
                return nil
            }
            self.horizon = horizon
            self.sessionID = sessionID
            self.frameID = frameID
        }
    }

    /// The sole formatter for composite memory IDs; bytes pinned by characterization tests.
    package var wireValue: String {
        switch horizon {
        case .durable:
            return "durable:\(frameID)"
        case .working, .episodic:
            return "\(horizon.rawValue):\(sessionID?.uuidString ?? "unknown"):\(frameID)"
        }
    }

    package static func durable(frameID: UInt64) -> MemoryReference {
        MemoryReference(horizon: .durable, sessionID: nil, frameID: frameID)!
    }

    package static func working(sessionID: UUID?, frameID: UInt64) -> MemoryReference {
        MemoryReference(horizon: .working, sessionID: sessionID, frameID: frameID)!
    }

    package static func episodic(sessionID: UUID?, frameID: UInt64) -> MemoryReference {
        MemoryReference(horizon: .episodic, sessionID: sessionID, frameID: frameID)!
    }
}
