import Foundation
import WaxVectorSearch

enum ProviderValidation {
    struct ProviderCheck {
        let name: StaticString
        let executionMode: ProviderExecutionMode

        init(name: StaticString, executionMode: ProviderExecutionMode) {
            self.name = name
            self.executionMode = executionMode
        }
    }

    static func validateOnDevice(
        _ checks: [ProviderCheck],
        orchestratorName: StaticString
    ) throws {
        for check in checks where check.executionMode != .onDeviceOnly {
            throw WaxError.io("\(orchestratorName) requires on-device \(check.name)")
        }
    }
}
