import Darwin
import Foundation
import Wax

#if canImport(ImageIO)
import CoreGraphics
#endif

@main
struct WaxRetiredVectorSweepHarness {
    static func main() async {
        #if canImport(ImageIO)
        do {
            try await run()
            FileHandle.standardOutput.write(Data("REBUILD_OK\n".utf8))
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
                embedder: PhotoHarnessEmbedder()
            )
        case "video":
            var config = VideoRAGConfig.default
            config.segmentDurationSeconds = 60
            config.segmentOverlapSeconds = 0
            config.maxSegmentsPerVideo = 1
            config.vectorEnginePreference = .cpuOnly
            _ = try await VideoRAGOrchestrator(
                storeURL: storeURL,
                config: config,
                embedder: VideoHarnessEmbedder()
            )
        default:
            throw HarnessError.unknownKind(kind)
        }
    }
    #endif

    private enum HarnessError: Error, CustomStringConvertible {
        case missingStore
        case unknownKind(String)

        var description: String {
            switch self {
            case .missingStore:
                return "missing WAX_RETIRED_VECTOR_SWEEP_STORE"
            case .unknownKind(let kind):
                return "unknown kind '\(kind)'"
            }
        }
    }
}

#if canImport(ImageIO)
private struct PhotoHarnessEmbedder: MultimodalEmbeddingProvider {
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

private struct VideoHarnessEmbedder: MultimodalEmbeddingProvider {
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
