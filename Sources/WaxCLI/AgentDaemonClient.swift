import Foundation
import Wax

enum AgentBrokerPolicy {
    static func shouldUseBroker(store: StoreOptions, commit: Bool = true) -> Bool {
        commit && !store.directStore
    }

    static func shouldUseBroker(store: VectorStoreOptions, commit: Bool = true) -> Bool {
        commit && !store.directStore
    }
}

enum AgentBrokerCLI {
    static func configuration(
        storePath: String,
        embedderChoice: String,
        noEmbedder: Bool,
        requireVector: Bool,
        embedderTuning: CommandLineEmbedderRuntimeTuning
    ) throws -> AgentBrokerConfiguration {
        let currentExecutable = try Pathing.resolveSelfExecutablePath()
        let brokerExecutable = AgentBrokerPathing.resolveBrokerCLIPath(currentExecutablePath: currentExecutable)
        return try AgentBrokerPathing.configuration(
            brokerExecutablePath: brokerExecutable,
            storePath: storePath,
            embedderChoice: embedderChoice,
            noEmbedder: noEmbedder,
            requireVector: requireVector,
            embedderTuning: embedderTuning
        )
    }

    static func perform(
        command: String,
        arguments: [String: AgentBrokerValue],
        storePath: String,
        embedderChoice: String,
        noEmbedder: Bool,
        requireVector: Bool,
        embedderTuning: CommandLineEmbedderRuntimeTuning,
        shutdownIfStarted: Bool = true
    ) async throws -> AgentBrokerResponse {
        let configuration = try configuration(
            storePath: storePath,
            embedderChoice: embedderChoice,
            noEmbedder: noEmbedder,
            requireVector: requireVector,
            embedderTuning: embedderTuning
        )
        let response = try await AgentBrokerClient.perform(
            request: AgentBrokerRequest(command: command, arguments: arguments),
            configuration: configuration,
            shutdownIfStarted: shutdownIfStarted
        )
        guard response.ok else {
            throw CLIError(response.error ?? "Broker command failed")
        }
        return response
    }
}
