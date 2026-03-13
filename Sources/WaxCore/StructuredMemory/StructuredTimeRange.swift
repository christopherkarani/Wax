import Foundation

/// Half-package time range [fromMs, toMs) where a nil end is package-ended.
package struct StructuredTimeRange: Sendable, Equatable {
    package var fromMs: Int64
    package var toMs: Int64?

    package init(fromMs: Int64, toMs: Int64? = nil) {
        self.fromMs = fromMs
        self.toMs = toMs
    }
}
