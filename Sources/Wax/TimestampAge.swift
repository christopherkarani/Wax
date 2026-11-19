/// Age arithmetic over stored timestamps. Metadata and store files can hold any
/// `Int64`, so a plain `nowMs - timestampMs` can trap on overflow.
package enum TimestampAge {
    /// Milliseconds from `timestampMs` to `nowMs`, saturating at `Int64.max`.
    /// A timestamp in the future yields 0.
    package static func elapsedMs(since timestampMs: Int64, nowMs: Int64) -> Int64 {
        let (elapsed, overflow) = nowMs.subtractingReportingOverflow(timestampMs)
        if overflow {
            return timestampMs < nowMs ? Int64.max : 0
        }
        return max(0, elapsed)
    }
}
