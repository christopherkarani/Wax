import Darwin
import Foundation
import Wax
import WaxCore

#if canImport(ImageIO)
import CoreGraphics
#endif

@main
struct WaxRetiredVectorSweepHarness {
    static func main() async {
        #if canImport(ImageIO)
        do {
            let kind = ProcessInfo.processInfo.environment["WAX_RETIRED_VECTOR_SWEEP_KIND"] ?? "photo"
            try await run()
            let ok = kind.contains("pending") ? "PENDING_OK\n" : "REBUILD_OK\n"
            FileHandle.standardOutput.write(Data(ok.utf8))
            // Abrupt termination: no flush, no close, no Swift teardown.
            // Do not fsync stdout — the parent reads a pipe (ENOTSUP).
            _exit(0)
        } catch {
            FileHandle.standardError.write(Data("FAIL \(error)\n".utf8))
            _exit(2)
        }
        #else
        FileHandle.standardError.write(Data("FAIL ImageIO unavailable\n".utf8))
        _exit(2)
        #endif
    }

    #if canImport(ImageIO)
    private static func run() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let storePath = env["WAX_RETIRED_VECTOR_SWEEP_STORE"], !storePath.isEmpty else {
            throw HarnessError.missingStore
        }
        let kind = env["WAX_RETIRED_VECTOR_SWEEP_KIND"] ?? "photo"
        let storeURL = URL(fileURLWithPath: storePath)

        switch kind {
        case "photo":
            var config = PhotoRAGConfig.default
            config.includeThumbnailsInContext = false
            config.includeRegionCropsInContext = false
            config.enableOCR = false
            config.enableRegionEmbeddings = false
            config.vectorEnginePreference = .cpuOnly
            _ = try await PhotoRAGOrchestrator(
                storeURL: storeURL,
                config: config,
                embedder: PhotoHarnessEmbedder(),
                walSizeBytes: Memory.Config.defaultWalSizeBytes
            )
        case "photo-pending-delete":
            try await writePhotoPendingDeletes(storeURL: storeURL)
        case "photo-pending-ingest":
            try await writePhotoPendingIngest(storeURL: storeURL)
        case "video":
            var config = VideoRAGConfig.default
            config.segmentDurationSeconds = 60
            config.segmentOverlapSeconds = 0
            config.maxSegmentsPerVideo = 1
            config.vectorEnginePreference = .cpuOnly
            _ = try await VideoRAGOrchestrator(
                storeURL: storeURL,
                config: config,
                embedder: VideoHarnessEmbedder(),
                walSizeBytes: Memory.Config.defaultWalSizeBytes
            )
        case "video-pending-delete":
            try await writeVideoPendingDeletes(storeURL: storeURL)
        case "video-pending-ingest":
            try await writeVideoPendingIngest(storeURL: storeURL)
        default:
            throw HarnessError.unknownKind(kind)
        }
    }
    #endif

    private enum HarnessError: Error, CustomStringConvertible {
        case missingStore
        case unknownKind(String)
        case missingLiveRoot(String)

        var description: String {
            switch self {
            case .missingStore:
                return "missing WAX_RETIRED_VECTOR_SWEEP_STORE"
            case .unknownKind(let kind):
                return "unknown kind '\(kind)'"
            case .missingLiveRoot(let detail):
                return "missing live root: \(detail)"
            }
        }
    }

    private static func writePhotoPendingDeletes(storeURL: URL) async throws {
        let wax = try await Wax.open(at: storeURL)
        let metas = await wax.frameMetas()
        let liveRootIDs = Set(metas.compactMap { meta -> UInt64? in
            guard meta.kind == PhotoFrameKind.root.rawValue,
                  meta.status != .deleted,
                  meta.supersededBy == nil
            else { return nil }
            return meta.id
        })
        var toDelete = liveRootIDs
        for meta in metas {
            if let parent = meta.parentId, liveRootIDs.contains(parent) {
                toDelete.insert(meta.id)
            }
        }
        for frameId in toDelete.sorted() {
            try await wax.delete(frameId: frameId)
        }
        // Leave pending WAL durable in the page cache; do not close (close commits).
    }

    private static func writePhotoPendingIngest(storeURL: URL) async throws {
        let wax = try await Wax.open(at: storeURL)
        let metas = await wax.frameMetas()
        guard let live = metas.first(where: {
            $0.kind == PhotoFrameKind.root.rawValue
                && $0.status != .deleted
                && $0.supersededBy == nil
        }) else {
            throw HarnessError.missingLiveRoot("photo.root")
        }
        let assetID = live.metadata?.entries[PhotoMetadataKey.assetID.rawValue] ?? "pending-ingest-asset"
        var entries = live.metadata?.entries ?? [:]
        entries[PhotoMetadataKey.assetID.rawValue] = assetID
        let newRoot = try await wax.put(
            Data("pending-ingest-root".utf8),
            options: FrameMetaSubset(
                kind: PhotoFrameKind.root.rawValue,
                metadata: Metadata(entries)
            )
        )
        try await wax.supersede(supersededId: live.id, supersedingId: newRoot)
    }

    private static func writeVideoPendingDeletes(storeURL: URL) async throws {
        let wax = try await Wax.open(at: storeURL)
        let metas = await wax.frameMetas()
        let liveRootIDs = Set(metas.compactMap { meta -> UInt64? in
            guard meta.kind == VideoFrameKind.root.rawValue,
                  meta.status != .deleted,
                  meta.supersededBy == nil
            else { return nil }
            return meta.id
        })
        var toDelete = liveRootIDs
        for meta in metas {
            if let parent = meta.parentId, liveRootIDs.contains(parent) {
                toDelete.insert(meta.id)
            }
        }
        for frameId in toDelete.sorted() {
            try await wax.delete(frameId: frameId)
        }
    }

    private static func writeVideoPendingIngest(storeURL: URL) async throws {
        let wax = try await Wax.open(at: storeURL)
        let metas = await wax.frameMetas()
        guard let live = metas.first(where: {
            $0.kind == VideoFrameKind.root.rawValue
                && $0.status != .deleted
                && $0.supersededBy == nil
        }) else {
            throw HarnessError.missingLiveRoot("video.root")
        }
        let entries = live.metadata?.entries ?? [:]
        let newRoot = try await wax.put(
            Data("pending-ingest-video-root".utf8),
            options: FrameMetaSubset(
                kind: VideoFrameKind.root.rawValue,
                metadata: Metadata(entries)
            )
        )
        try await wax.supersede(supersededId: live.id, supersedingId: newRoot)
    }
}

#if canImport(ImageIO)
private struct PhotoHarnessEmbedder: CGImageEmbeddingProvider {
    let executionMode: ProviderExecutionMode = .onDeviceOnly
    let dimensions: Int = 4
    let normalize: Bool = true
    let identity: EmbeddingIdentity? = EmbeddingIdentity(
        provider: "Mock",
        model: "DeterministicMultimodal",
        dimensions: 4,
        normalized: true
    )

    func embed(text: String) async throws -> [Float] {
        _ = text
        return [1, 0, 0, 0]
    }

    func embed(image: CGImage) async throws -> [Float] {
        _ = image
        return [0, 1, 0, 0]
    }
}

private struct VideoHarnessEmbedder: CGImageEmbeddingProvider {
    let executionMode: ProviderExecutionMode = .onDeviceOnly
    let dimensions: Int = 8
    let normalize: Bool = true
    let identity: EmbeddingIdentity? = EmbeddingIdentity(
        provider: "Test",
        model: "DeleteDurabilityVideo",
        dimensions: 8,
        normalized: true
    )

    func embed(text: String) async throws -> [Float] {
        _ = text
        return [1, 0, 0, 0, 0, 0, 0, 0]
    }

    func embed(image: CGImage) async throws -> [Float] {
        _ = image
        return [1, 0, 0, 0, 0, 0, 0, 0]
    }
}
#endif
