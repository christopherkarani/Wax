import Foundation

/// Test-only hooks for a daemon a test launches, set through that daemon's
/// environment. Unset in production, where `current` is nil.
///
/// `WAX_BROKER_TEST_HOLD_COMMAND` names a socket command to hold once it is
/// admitted, before it reaches the service, until a `release` file appears in
/// `WAX_BROKER_TEST_HOLD_DIR`. The daemon writes markers to that directory:
/// - `held`: the command is admitted and waiting
/// - `draining`: shutdown has started its drain
/// - `responded`: the held command's response was written, or its client was gone
struct DaemonTestHooks: Sendable {
    static let current = DaemonTestHooks(environment: ProcessInfo.processInfo.environment)

    let holdCommand: String
    let directory: URL

    init?(environment: [String: String]) {
        guard let command = environment["WAX_BROKER_TEST_HOLD_COMMAND"], !command.isEmpty,
              let path = environment["WAX_BROKER_TEST_HOLD_DIR"], !path.isEmpty
        else {
            return nil
        }
        holdCommand = command
        directory = URL(fileURLWithPath: path, isDirectory: true)
    }

    func holdIfMatching(_ command: String) async {
        guard command == holdCommand else { return }
        mark("held")
        let release = directory.appendingPathComponent("release").path
        while !FileManager.default.fileExists(atPath: release) {
            try? await Task.sleep(for: .milliseconds(20))
        }
    }

    func markResponded(_ command: String) {
        guard command == holdCommand else { return }
        mark("responded")
    }

    func markDraining() {
        mark("draining")
    }

    private func mark(_ name: String) {
        FileManager.default.createFile(atPath: directory.appendingPathComponent(name).path, contents: nil)
    }
}
