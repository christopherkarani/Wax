import Foundation
import Testing
@testable import Wax

@Test
func memoryIDParseRoundTripsDurableWire() throws {
    let id = try MemoryID.parse("durable:42")
    #expect(id == .durable(frameID: 42))
    #expect(id.wire == "durable:42")
    #expect(id.horizon == .durable)
    #expect(id.sessionID == nil)
    #expect(id.frameID == 42)
}

@Test
func memoryIDParseRoundTripsWorkingWire() throws {
    let sessionID = UUID()
    let raw = "working:\(sessionID.uuidString):7"
    let id = try MemoryID.parse(raw)
    #expect(id == .working(sessionID: sessionID, frameID: 7))
    #expect(id.wire == raw)
    #expect(id.horizon == .working)
    #expect(id.sessionID == sessionID)
}

@Test
func memoryIDParseRoundTripsEpisodicWire() throws {
    let sessionID = UUID()
    let raw = "episodic:\(sessionID.uuidString):3"
    let id = try MemoryID.parse(raw)
    #expect(id == .episodic(sessionID: sessionID, frameID: 3))
    #expect(id.wire == raw)
}

@Test
func memoryIDParseRejectsDurableWithSessionToken() {
    let sessionID = UUID()
    #expect(throws: BrokerValidationError.self) {
        try MemoryID.parse("durable:\(sessionID.uuidString):1")
    }
}

@Test
func memoryIDParseRejectsWorkingWithoutSession() {
    #expect(throws: BrokerValidationError.self) {
        try MemoryID.parse("working:1")
    }
}

@Test
func memoryIDWireNeverEmitsUnknownSessionToken() {
    let sessionID = UUID()
    #expect(!MemoryID.working(sessionID: sessionID, frameID: 1).wire.contains("unknown"))
    #expect(!MemoryID.episodic(sessionID: sessionID, frameID: 1).wire.contains("unknown"))
    #expect(!MemoryID.durable(frameID: 9).wire.contains("unknown"))
}
