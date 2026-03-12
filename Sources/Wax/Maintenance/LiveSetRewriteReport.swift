import Foundation

package struct LiveSetRewriteReport: Sendable, Equatable {
    package var sourceURL: URL
    package var destinationURL: URL
    package var frameCount: Int
    package var activeFrameCount: Int
    package var droppedPayloadFrames: Int
    package var deletedFrameCount: Int
    package var supersededFrameCount: Int
    package var copiedLexIndex: Bool
    package var copiedVecIndex: Bool
    package var logicalBytesBefore: UInt64
    package var logicalBytesAfter: UInt64
    package var allocatedBytesBefore: UInt64
    package var allocatedBytesAfter: UInt64
    package var durationMs: Double

    package init(
        sourceURL: URL,
        destinationURL: URL,
        frameCount: Int,
        activeFrameCount: Int,
        droppedPayloadFrames: Int,
        deletedFrameCount: Int,
        supersededFrameCount: Int,
        copiedLexIndex: Bool,
        copiedVecIndex: Bool,
        logicalBytesBefore: UInt64,
        logicalBytesAfter: UInt64,
        allocatedBytesBefore: UInt64,
        allocatedBytesAfter: UInt64,
        durationMs: Double
    ) {
        self.sourceURL = sourceURL
        self.destinationURL = destinationURL
        self.frameCount = frameCount
        self.activeFrameCount = activeFrameCount
        self.droppedPayloadFrames = droppedPayloadFrames
        self.deletedFrameCount = deletedFrameCount
        self.supersededFrameCount = supersededFrameCount
        self.copiedLexIndex = copiedLexIndex
        self.copiedVecIndex = copiedVecIndex
        self.logicalBytesBefore = logicalBytesBefore
        self.logicalBytesAfter = logicalBytesAfter
        self.allocatedBytesBefore = allocatedBytesBefore
        self.allocatedBytesAfter = allocatedBytesAfter
        self.durationMs = durationMs
    }
}
