#if MCPServer
import Foundation

/// Single-flight `roots/list` for one connection, with a failure backoff.
///
/// An SDK request the client never answers stays parked (with its
/// `pendingRequests` entry) until the server stops, whatever the caller's
/// deadline. So callers join the one outstanding request instead of issuing
/// another, and for `backoff` after a request failed or ran past `timeout`
/// they get no roots at once instead of waiting again. A late answer, or any
/// answer, clears the backoff; an empty answer is not a failure, so roots a
/// client advertises later still heal the connection.
final class MCPRootsFetchGate: @unchecked Sendable {
    static let defaultBackoff: Duration = .seconds(30)

    private let timeout: Duration
    private let backoff: Duration
    private let clock = ContinuousClock()
    private let lock = NSLock()
    private var inFlight: Task<[String]?, Never>?
    private var failedAt: ContinuousClock.Instant?

    init(
        timeout: Duration = .seconds(MCPRootsFetcher.timeoutSeconds),
        backoff: Duration = MCPRootsFetchGate.defaultBackoff
    ) {
        self.timeout = timeout
        self.backoff = backoff
    }

    /// `request` returns nil when `roots/list` failed.
    func fetch(_ request: @escaping @Sendable () async -> [String]?) async -> [String] {
        guard let task = claim(request) else { return [] }
        guard let roots = await MCPDeadline.value(of: task, within: timeout, orElse: nil) else {
            recordTimeout(of: task)
            return []
        }
        return roots
    }

    /// The outstanding request to join, a new one, or nil while backing off.
    private func claim(
        _ request: @escaping @Sendable () async -> [String]?
    ) -> Task<[String]?, Never>? {
        lock.lock()
        defer { lock.unlock() }
        if let failedAt, clock.now - failedAt < backoff { return nil }
        if let inFlight { return inFlight }
        let task = Task { [weak self] in
            let roots = await request()
            self?.finish(answered: roots != nil)
            return roots
        }
        inFlight = task
        return task
    }

    private func finish(answered: Bool) {
        lock.lock()
        defer { lock.unlock() }
        inFlight = nil
        failedAt = answered ? nil : clock.now
    }

    /// Only a request still outstanding counts as timed out: one that
    /// answered just after the deadline has already settled the backoff.
    private func recordTimeout(of task: Task<[String]?, Never>) {
        lock.lock()
        defer { lock.unlock() }
        if inFlight == task { failedAt = clock.now }
    }
}
#endif
