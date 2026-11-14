#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

// POSIX constants and calls whose Swift spelling differs between Darwin and Glibc.
// On Glibc `SOCK_STREAM` imports as an enum and `SHUT_WR` as `Int`; on Darwin both are `Int32`.

package enum TestPOSIX {
    /// `SOCK_STREAM` as the `Int32` that `socket(2)` takes.
    #if canImport(Darwin)
    package static let sockStream: Int32 = SOCK_STREAM
    #else
    package static let sockStream: Int32 = Int32(SOCK_STREAM.rawValue)
    #endif

    /// `SHUT_WR` as the `Int32` that `shutdown(2)` takes.
    #if canImport(Darwin)
    package static let shutWrite: Int32 = SHUT_WR
    #else
    package static let shutWrite: Int32 = Int32(SHUT_WR)
    #endif

    /// `kill(2)`, for call sites where a member named `kill` would shadow the libc function.
    @discardableResult
    package static func kill(_ pid: pid_t, _ signal: Int32) -> Int32 {
        #if canImport(Darwin)
        return Darwin.kill(pid, signal)
        #else
        return Glibc.kill(pid, signal)
        #endif
    }
}
