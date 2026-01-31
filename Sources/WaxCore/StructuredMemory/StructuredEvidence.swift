import Foundation

/// Provenance evidence pointing back to Wax frames/chunks.
public struct StructuredEvidence: Sendable, Equatable {
    public var sourceFrameId: UInt64
    public var chunkIndex: UInt32?
    public var spanUTF8: Range<Int>?
    public var extractorId: String
    public var extractorVersion: String
    public var confidence: Double?
    public var assertedAtMs: Int64

    public init(
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
