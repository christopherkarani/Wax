import Foundation

/// Single wall-clock source for broker timestamps (Unix epoch milliseconds).
package enum BrokerClock {
    package static func nowMs() -> Int64 {
        Int64(Date().timeIntervalSince1970 * 1000)
    }
}
