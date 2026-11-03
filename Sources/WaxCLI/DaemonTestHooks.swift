import Foundation

/// Test-only hooks for a daemon a test launches, set through that daemon's
/// environment. Debug builds only: in release builds `current` is always nil,
/// so the variables do nothing.
///
/// `WAX_BROKER_TEST_HOOKS_DIR` turns the hooks on. The daemon writes markers there:
/// - `listening`: the socket accepts connections (its file appears earlier, at bind)
/// - `held`: the held command is waiting
/// - `draining`: shutdown has started its drain
/// - `closing`: the drain is over and the store is about to close
/// - `responded`: the held command's response was written, or its client was gone
///
/// `WAX_BROKER_TEST_HOLD_COMMAND` names a socket command to hold until a
/// `release` file appears in that directory. By default it is held once
/// admitted, before it reaches the service. With
/// `WAX_BROKER_TEST_HOLD_POINT=service` it is held inside the service, while it
/// owns the store's locks.
struct DaemonTestHooks: Sendable {
    #if DEBUG
    static let current = DaemonTestHooks(environment: ProcessInfo.processInfo.environment)
    #else
    static let current: DaemonTestHooks? = nil
    #endif

    let directory: URL
    let holdCommand: String?
    let holdsInService: Bool

    init?(environment: [String: String]) {
        guard let path = environment["WAX_BROKER_TEST_HOOKS_DIR"], !path.isEmpty else {
            return nil
        }
        directory = URL(fileURLWithPath: path, isDirectory: true)
        holdCommand = environment["WAX_BROKER_TEST_HOLD_COMMAND"].flatMap { $0.isEmpty ? nil : $0 }
        holdsInService = environment["WAX_BROKER_TEST_HOLD_POINT"] == "service"
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

    func markListening() {
        mark("listening")
    }

    func markDraining() {
        mark("draining")
    }

    func markClosing() {
        mark("closing")
    }

    private func mark(_ name: String) {
        FileManager.default.createFile(atPath: directory.appendingPathComponent(name).path, contents: nil)
    }
}
