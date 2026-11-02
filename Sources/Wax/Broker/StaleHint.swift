import Foundation

/// One `stale_hint` rule for recall hits and primed items: a strictly newer
/// item of the same memory type, on the same topic, is in the same result set.
///
/// Topic uses `MemorySemantics.isStaleTwin(older:newer:)` (auto-supersede's rule plus near-identical rewrites), so two
/// unrelated decisions never mark each other stale. Unknown timestamps (`<= 0`)
/// are never flagged and never count as newer; equal timestamps are not newer.
package enum StaleHint {
    package struct Entry: Sendable {
        package var memoryType: String
        package var createdAtMs: Int64
        package var signature: MemorySemantics.TextSignature

        package init(memoryType: String, createdAtMs: Int64, text: String) {
            self.init(memoryType: memoryType, createdAtMs: createdAtMs, signature: MemorySemantics.TextSignature(text))
        }

        package init(memoryType: String, createdAtMs: Int64, signature: MemorySemantics.TextSignature) {
            self.memoryType = memoryType
            self.createdAtMs = createdAtMs
            self.signature = signature
        }
    }

    /// Per-entry flags, in input order.
    package static func flags(for entries: [Entry]) -> [Bool] {
        entries.indices.map { index in
            let entry = entries[index]
            guard entry.createdAtMs > 0 else { return false }
            return entries.indices.contains { otherIndex in
                guard otherIndex != index else { return false }
                let other = entries[otherIndex]
                guard other.memoryType == entry.memoryType else { return false }
                guard other.createdAtMs > entry.createdAtMs else { return false }
                return MemorySemantics.isStaleTwin(older: entry.signature, newer: other.signature)
            }
        }
    }
}
