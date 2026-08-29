import ArgumentParser
import Foundation
import Wax

struct MemoryMaintainCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "memory-maintain",
        abstract: "Dry-run or apply session harvest, reclaim, and working-set quarantine"
    )

    @OptionGroup var store: VectorStoreOptions

    @Flag(
        name: .customLong("apply"),
        help: "Apply harvest, reclaim, and quarantine. Default is dry-run."
    )
    var apply = false

    @Flag(
        name: .customLong("dry-run"),
        help: "Report planned actions without mutating (default)."
    )
    var dryRun = false

    @Flag(
        name: .customLong("force-reclaim"),
        help: "Unlink ended session stores even if harvest failed."
    )
    var forceReclaim = false

    func runAsync() async throws {
        guard !store.directStore else {
            throw CLIError("--direct-store is not supported for broker parity commands")
        }
        let response = try await AgentBrokerCLI.perform(
            command: "memory_maintain",
            arguments: [
                "apply": .bool(apply && !dryRun),
                "force_reclaim": .bool(forceReclaim),
            ],
            storePath: store.storePath,
            embedderChoice: store.embedder.rawValue,
            noEmbedder: store.noEmbedder,
            requireVector: store.requireVector,
            embedderTuning: store.embedderTuning
        )
        let payload = try brokerPayloadObject(response)
        switch store.format {
        case .json:
            printJSON(payload.toJSONObject())
        case .text:
            print(brokerString(payload, "display_text") ?? "Maintain complete.")
        }
    }
}
