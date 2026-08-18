import Wax

enum FoundationModelsDemoSupport {
    static let instructions =
        "You answer only from the photo evidence in the prompt. If it is missing, say you cannot find it."

    static var sessionConfiguration: FoundationModelsMemorySessionConfig {
        FoundationModelsMemorySessionConfig(
            persistencePolicy: .none,
            contextStrategy: .promptAugmentation,
            includeMemoryTools: false
        )
    }
}
