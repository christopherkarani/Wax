import Foundation
import WaxCore

package enum StoreLockProbe {
    package static func preflightExclusiveAccess(at url: URL, timeout: Duration?) throws {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        let lock = try FileLock.acquire(at: url, mode: .exclusive, timeout: timeout)
        try lock.release()
    }

    package static func decorateLockError(
        _ error: Error,
        at url: URL,
        timeout: Duration?,
        operation: String
    ) -> Error {
        guard let waxError = error as? WaxError,
              case let .lockUnavailable(details) = waxError
        else {
            return error
        }

        let timeoutLabel = timeout.map(formatDuration(_:)) ?? "the configured timeout"
        return WaxError.lockUnavailable(
            "\(details). Wax \(operation) failed fast after \(timeoutLabel) because another process is already using \(url.path). " +
                "Use a unique --store-path per client or agent, or stop the existing Wax process before retrying."
        )
    }

    private static func formatDuration(_ duration: Duration) -> String {
        let components = duration.components
        let seconds = Double(components.seconds) + (Double(components.attoseconds) / 1_000_000_000_000_000_000)
        if seconds == 0 {
            return "0s"
        }
        return String(format: "%.2fs", seconds)
    }
}
