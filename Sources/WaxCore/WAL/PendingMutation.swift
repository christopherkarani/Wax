import Foundation

package struct PutFrame: Equatable, Sendable {
    package var frameId: UInt64
    package var timestampMs: Int64
    package var options: FrameMetaSubset
    package var payloadOffset: UInt64
    package var payloadLength: UInt64
    package var canonicalEncoding: CanonicalEncoding
    package var canonicalLength: UInt64
    package var canonicalChecksum: Data
    package var storedChecksum: Data

    package init(
        frameId: UInt64,
        timestampMs: Int64,
        options: FrameMetaSubset,
        payloadOffset: UInt64,
        payloadLength: UInt64,
        canonicalEncoding: CanonicalEncoding,
        canonicalLength: UInt64,
        canonicalChecksum: Data,
        storedChecksum: Data
    ) {
        self.frameId = frameId
        self.timestampMs = timestampMs
        self.options = options
        self.payloadOffset = payloadOffset
        self.payloadLength = payloadLength
        self.canonicalEncoding = canonicalEncoding
        self.canonicalLength = canonicalLength
        self.canonicalChecksum = canonicalChecksum
        self.storedChecksum = storedChecksum
    }
}

package struct DeleteFrame: Equatable, Sendable {
    package var frameId: UInt64

    package init(frameId: UInt64) {
        self.frameId = frameId
    }
}

package struct SupersedeFrame: Equatable, Sendable {
    /// The older frame being superseded.
    package var supersededId: UInt64
    /// The newer frame that supersedes the old one.
    package var supersedingId: UInt64

    package init(supersededId: UInt64, supersedingId: UInt64) {
        self.supersededId = supersededId
        self.supersedingId = supersedingId
    }
}

package struct PutEmbedding: Equatable, Sendable {
    package var frameId: UInt64
    package var dimension: UInt32
    package var vector: [Float]

    package init(frameId: UInt64, dimension: UInt32, vector: [Float]) {
        self.frameId = frameId
        self.dimension = dimension
        self.vector = vector
    }
}

package enum WALEntry: Equatable, Sendable {
    case putFrame(PutFrame)
    case deleteFrame(DeleteFrame)
    case supersedeFrame(SupersedeFrame)
    case putEmbedding(PutEmbedding)
}

package struct PendingMutation: Equatable, Sendable {
    package var sequence: UInt64
    package var entry: WALEntry

    package init(sequence: UInt64, entry: WALEntry) {
        self.sequence = sequence
        self.entry = entry
    }
}
