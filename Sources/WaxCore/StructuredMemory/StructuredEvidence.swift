import Foundation

/// Provenance evidence pointing back to Wax frames/chunks.
package struct StructuredEvidence: Sendable, Equatable {
    package var sourceFrameId: UInt64
    package var chunkIndex: UInt32?
    package var spanUTF8: Range<Int>?
    package var extractorId: String
    package var extractorVersion: String
    package var confidence: Double?
    package var assertedAtMs: Int64

    package init(
        sourceFrameId: UInt64,
        chunkIndex: UInt32? = nil,
        spanUTF8: Range<Int>? = nil,
        extractorId: String,
        extractorVersion: String,
        confidence: Double? = nil,
        assertedAtMs: Int64
    ) {
        self.sourceFrameId = sourceFrameId
        self.chunkIndex = chunkIndex
        self.spanUTF8 = spanUTF8
        self.extractorId = extractorId
        self.extractorVersion = extractorVersion
        self.confidence = confidence
        self.assertedAtMs = assertedAtMs
    }
}
