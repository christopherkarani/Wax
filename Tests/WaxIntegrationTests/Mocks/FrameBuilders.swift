import Foundation
import Wax

enum FrameBuilders {
    static func photoRootMetadata(
        assetID: String,
        captureMs: Int64 = 1_700_000_000_000,
        isLocal: Bool = true
    ) -> Metadata {
        var metadata = Metadata()
        metadata.entries[PhotoMetadataKey.assetID.rawValue] = assetID
        metadata.entries[PhotoMetadataKey.captureMs.rawValue] = String(captureMs)
        metadata.entries[PhotoMetadataKey.isLocal.rawValue] = isLocal ? "true" : "false"
        metadata.entries[PhotoMetadataKey.pipelineVersion.rawValue] = "test"
        return metadata
    }

    static func videoRootMetadata(
        source: String = "file",
        sourceID: String,
        captureMs: Int64 = 1_700_000_000_000,
        isLocal: Bool = true
    ) -> Metadata {
        var metadata = Metadata()
        metadata.entries[VideoMetadataKey.source.rawValue] = source
        metadata.entries[VideoMetadataKey.sourceID.rawValue] = sourceID
        metadata.entries[VideoMetadataKey.captureMs.rawValue] = String(captureMs)
        metadata.entries[VideoMetadataKey.isLocal.rawValue] = isLocal ? "true" : "false"
        metadata.entries[VideoMetadataKey.pipelineVersion.rawValue] = "test"
        return metadata
    }
}
