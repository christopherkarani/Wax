import Foundation

/// Half-open time range [fromMs, toMs) where a nil end is open-ended.
public struct StructuredTimeRange: Sendable, Equatable {
    public var fromMs: Int64
    public var toMs: Int64?

    public init(fromMs: Int64, toMs: Int64? = nil) {
        self.fromMs = fromMs
        self.toMs = toMs
    }
}
