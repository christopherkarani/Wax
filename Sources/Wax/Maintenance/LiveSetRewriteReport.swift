import Foundation

public struct LiveSetRewriteReport: Sendable, Equatable {
    public var sourceURL: URL
    public var destinationURL: URL
    public var frameCount: Int
    public var activeFrameCount: Int
    public var droppedPayloadFrames: Int
    public var deletedFrameCount: Int
    public var supersededFrameCount: Int
    public var copiedLexIndex: Bool
    public var copiedVecIndex: Bool
    public var logicalBytesBefore: UInt64
    public var logicalBytesAfter: UInt64
    public var allocatedBytesBefore: UInt64
    public var allocatedBytesAfter: UInt64
    public var durationMs: Double

    public init(
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
