import Foundation

/// Keeps the shared broker up for as long as an MCP server is alive.
///
/// The broker exits once it has had no clients for its idle timeout, and
/// session-start primes never start one. Without a keepalive, every session
/// that began after a quiet spell, or after a crash, primed against nothing
/// and reported `broker_down` while dozens of servers were still running.
/// Each server pings the broker more often than the idle timeout and starts
/// a new one when nothing listens.
package enum BrokerKeepalive {
    package enum Outcome: Sendable, Equatable {
        /// The broker replied; the ping counts as activity.
        case answered
        /// The socket accepts connections but gave no reply in time. The
        /// broker answers `ping` without waiting behind running commands, so
        /// this is a stall, but one miss is left alone: replacing a broker
        /// drops its work.
        case unanswered
        /// Nothing listened, so a broker was started or found starting.
        case started
        /// A broker that missed consecutive pings went through
        /// ``AgentBrokerClient/ensureAvailable(configuration:startTimeoutSecondsOverride:onBrokerLaunched:)``,
        /// which pings it once more and replaces it only if it is still mute.
        case recovered
    }

    package static let intervalEnvKey = "WAX_BROKER_KEEPALIVE_SECS"
    private static let maximumIntervalSeconds: Double = 60
    /// Low enough to stay inside a 1s idle timeout, high enough to never spin.
    private static let minimumIntervalSeconds: Double = 0.2
    /// Consecutive unanswered pings before the keepalive asks for recovery.
    package static let unansweredLimit = 2

    /// Seconds between pings: `WAX_BROKER_KEEPALIVE_SECS` when set (0 turns the
    /// keepalive off), else a third of the broker idle timeout, at most 60s.
    package static func intervalSeconds(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Double? {
        if let raw = environment[intervalEnvKey]?.trimmingCharacters(in: .whitespacesAndNewlines),
           let value = Double(raw), value.isFinite {
            return value > 0 ? max(minimumIntervalSeconds, value) : nil
        }
        let idle = AgentBrokerClient.configuredIdleTimeoutSeconds(environment: environment)
        return max(minimumIntervalSeconds, min(maximumIntervalSeconds, idle / 3))
    }

    /// One keepalive check. Starts a broker when nothing listens. A broker
    /// whose socket accepts connections is only handed to recovery once it has
    /// missed ``unansweredLimit`` pings in a row (`priorUnanswered` counts the
    /// misses before this one).
    package static func tick(
        configuration: AgentBrokerConfiguration,
        priorUnanswered: Int = 0,
        pingTimeoutSeconds: TimeInterval = 5
    ) async throws -> Outcome {
        // Any reply counts, including an older broker's refusal of `ping`.
        let reply = try? await AgentBrokerClient.probeOffPool(
            request: AgentBrokerRequest(id: "__keepalive__", command: "ping"),
            configuration: configuration,
            timeoutSeconds: pingTimeoutSeconds
        )
        if reply != nil {
            return .answered
        }
        // `try?` above swallows cancellation; a server that is exiting must not
        // start a broker on its way out.
        try Task.checkCancellation()
        if await AgentBrokerClient.isSocketLiveOffPool(socketPath: configuration.socketPath) {
            guard priorUnanswered + 1 >= unansweredLimit else {
                return .unanswered
            }
            _ = try await AgentBrokerClient.ensureAvailable(configuration: configuration)
            return .recovered
        }
        _ = try await AgentBrokerClient.ensureAvailable(configuration: configuration)
        return .started
    }

    /// Runs ``tick(configuration:priorUnanswered:pingTimeoutSeconds:)`` every
    /// `intervalSeconds` until the task is cancelled. Failures go to `onError`
    /// and the loop goes on.
    package static func run(
        configuration: AgentBrokerConfiguration,
        intervalSeconds: Double,
        onError: @escaping @Sendable (Error) -> Void
    ) async {
        var unanswered = 0
        while !Task.isCancelled {
            do {
                try await Task.sleep(for: .seconds(intervalSeconds))
            } catch {
                return
            }
            do {
                let outcome = try await tick(configuration: configuration, priorUnanswered: unanswered)
                unanswered = outcome == .unanswered ? unanswered + 1 : 0
            } catch is CancellationError {
                return
            } catch {
                // A failed recovery or start is retried on the next tick.
                unanswered = 0
                onError(error)
            }
        }
    }
}
