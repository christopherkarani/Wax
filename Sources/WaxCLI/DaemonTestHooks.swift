import Foundation

/// Test-only hooks for a daemon a test launches, set through that daemon's
/// environment. Debug builds only: in release builds `current` is always nil,
/// so the variables do nothing.
///
/// `WAX_BROKER_TEST_HOOKS_DIR` turns the hooks on. The daemon writes markers there:
/// - `listening`: the socket accepts connections (its file appears earlier, at bind)
/// - `held`: the held command is waiting
/// - `signalled`: the first shutdown signal was handled
/// - `draining`: shutdown has started its drain
/// - `closing`: the drain is over and the store is about to close
/// - `closed`: the store has closed
/// - `responded`: the held command's response was written, or its client was gone
///
/// `WAX_BROKER_TEST_HOLD_COMMAND` names a socket command to hold until a
/// `release` file appears in that directory. By default it is held once
/// admitted, before it reaches the service. With
/// `WAX_BROKER_TEST_HOLD_POINT=service` it is held inside the service, while it
/// owns the store's locks.
///
/// `WAX_BROKER_TEST_READ_DEADLINE_SECS` replaces the 5s request read deadline,
/// so a test's own scheduling delays cannot run a client out of time.
struct DaemonTestHooks: Sendable {
    #if DEBUG
    static let current = DaemonTestHooks(environment: ProcessInfo.processInfo.environment)
    #else
    static let current: DaemonTestHooks? = nil
    #endif

    let directory: URL
    let holdCommand: String?
    let holdsInService: Bool
    let requestReadSeconds: TimeInterval?

    init?(environment: [String: String]) {
        guard let path = environment["WAX_BROKER_TEST_HOOKS_DIR"], !path.isEmpty else {
            return nil
        }
        directory = URL(fileURLWithPath: path, isDirectory: true)
        holdCommand = environment["WAX_BROKER_TEST_HOLD_COMMAND"].flatMap { $0.isEmpty ? nil : $0 }
        holdsInService = environment["WAX_BROKER_TEST_HOLD_POINT"] == "service"
        requestReadSeconds = environment["WAX_BROKER_TEST_READ_DEADLINE_SECS"]
            .flatMap(TimeInterval.init)
            .flatMap { $0.isFinite && $0 > 0 ? $0 : nil }
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

    func markSignalled() {
        mark("signalled")
    }

    func markDraining() {
        mark("draining")
    }

    func markClosing() {
        mark("closing")
    }

    func markClosed() {
        mark("closed")
    }

    /// Each marker holds the Unix time it was written, so a test can show
    /// where shutdown spent its time.
    private func mark(_ name: String) {
        let time = Data(String(Date().timeIntervalSince1970).utf8)
        FileManager.default.createFile(atPath: directory.appendingPathComponent(name).path, contents: time)
    }
}
