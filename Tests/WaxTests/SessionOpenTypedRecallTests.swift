import Foundation
import Testing

@Test
func sessionOpenConstructsRecallWithoutBagDecode() throws {
    let repoRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
    let source = try String(
        contentsOf: repoRoot.appendingPathComponent("Sources/Wax/Broker/AgentBrokerService.swift"),
        encoding: .utf8
    )
    #expect(!source.contains("BrokerCommand.Recall.decode(BrokerArguments"))
    #expect(source.contains("identity: .project(workingSessionID: sessionUUID)"))
    #expect(source.contains("identity: .global(workingSessionID: sessionUUID)"))
    #expect(source.contains("memoryTypes: [.userPreference]"))
}
