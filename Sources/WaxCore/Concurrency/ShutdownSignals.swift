import Dispatch
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// Watches SIGTERM and SIGINT through dispatch signal sources, so the handler
/// runs on a queue instead of in async-signal context.
///
/// Darwin delivers signal sources through kqueue `EVFILT_SIGNAL`. That ranks
/// below the signal disposition, so the default action, which terminates the
/// process, must be set to `SIG_IGN` first.
///
/// On Linux, libdispatch installs its own `sigaction` handler when the source
/// registers. The handler blocks the signal and re-raises it to the manager
/// thread, which reads it from a `signalfd`. So the disposition is left alone
/// there, as in swift-service-lifecycle. The mask is also not blocked
/// process-wide: Foundation's `Process` does not reset the mask on Linux, so
/// every child, such as a git probe, would inherit SIGTERM blocked, and
/// `Process.terminate()` would stop working on it.
package enum ShutdownSignals {
    package static let watched: [Int32] = [SIGTERM, SIGINT]

    /// The handlers' own serial queue. Serial queues are overcommit, so this one
    /// gets a thread even when every worker of the global queues is blocked,
    /// for example by socket clients still sending their requests, each waiting
    /// in `BlockingWork`. On `.global()` a signal can then wait until one of
    /// them finishes, and a second signal cannot force the exit.
    package static let handlerQueue = DispatchQueue(
        label: "com.wax.shutdown-signals",
        qos: .userInteractive
    )

    /// Starts the sources. Keep them alive for as long as the signals should be
    /// handled, and cancel them when done. `handler` receives the signal number,
    /// once per signal: signals that arrive before the handler runs are merged
    /// into one event, so it is called that many times.
    package static func observe(
        queue: DispatchQueue = handlerQueue,
        handler: @escaping @Sendable (Int32) -> Void
    ) -> [DispatchSourceSignal] {
        watched.map { signalNumber in
            #if canImport(Darwin)
            signal(signalNumber, SIG_IGN)
            #endif
            let source = DispatchSource.makeSignalSource(signal: signalNumber, queue: queue)
            // Strong capture: `DispatchSourceSignal` is not class-bound on Linux,
            // and cancelling the source releases the handler.
            source.setEventHandler {
                for _ in 0..<max(1, source.data) {
                    handler(signalNumber)
                }
            }
            source.resume()
            return source
        }
    }
}
