# Photo RAG

Index local images or Photos-library assets and search them with ``PhotoMemory``.

## Overview

``PhotoMemory`` is the public, owning facade for on-device photo memory. Open a store with a ``MultimodalEmbeddingProvider`` (byte-oriented `embed(text:)` and `embed(imageData:format:)`). The provider must declare ``ProviderExecutionMode``: `.onDeviceOnly` or `.mayUseNetwork`. Default ``PhotoMemory/Config-swift.struct/requireOnDeviceProviders`` rejects `.mayUseNetwork`.

`PhotoRAGOrchestrator` and the CGImage pipeline remain package-only internals. Application code should not construct them.

## Open, ingest, search

```swift compile
import Foundation
import Wax

struct DocsPhotoEmbedder: MultimodalEmbeddingProvider {
    let dimensions = 4
    let normalize = true
    let identity: EmbeddingIdentity? = .init(
        provider: "docs",
        model: "photo",
        dimensions: 4,
        normalized: true
    )
    let executionMode: ProviderExecutionMode = .onDeviceOnly

    func embed(text: String) async throws -> [Float] {
        text.localizedCaseInsensitiveContains("receipt")
            ? [0, 1, 0, 0]
            : [1, 0, 0, 0]
    }

    func embed(imageData: Data, format: WaxImageFormat) async throws -> [Float] {
        _ = imageData
        _ = format
        return [0, 1, 0, 0]
    }
}

func photoMemoryDemo() async throws {
    let storeURL = URL.documentsDirectory.appending(path: "photos.wax")
    let photos = try await PhotoMemory.open(
        at: storeURL,
        embedding: DocsPhotoEmbedder()
    )
    try await photos.ingest(files: [
        PhotoMemory.File(id: "receipt", url: URL.documentsDirectory.appending(path: "receipt.png"))
    ])
    let hits = try await photos.search(.init(text: "receipt", resultLimit: 5))
    _ = hits.items.first?.assetID
    _ = hits.items.first?.thumbnail
    try await photos.close()
}
```

``PhotoMemory/Item/thumbnail`` is PNG `Data?` when ``PhotoMemory/Config-swift.struct/includeThumbnailsInContext`` is true and a pixel source is still available. Ingest takes ``PhotoMemory/File`` values (not a separate `IngestItem` type).

Optional OCR and captions use ``PhotoOCRProvider`` and ``PhotoCaptionProvider`` (also byte-oriented, with `executionMode`).

## How photos are stored

Each photo is represented as a hierarchy of frames. This layout is an implementation detail of the package-only orchestrator:

| Frame Kind | Content |
|------------|---------|
| `root` | Photo metadata (asset ID, capture date, camera, GPS) |
| `ocrBlock` | Individual OCR text blocks |
| `ocrSummary` | Concatenated OCR text for the full image |
| `captionShort` | Short image caption |
| `tags` | Metadata keywords, or caption-derived search terms when no keywords are present |
| `region` | Bounding box regions of interest |
| `syncState` | Library sync checkpoint |

Ingestion supports Photos-library sync, local image files, and optional OCR, captions, metadata tags, and region evidence. Providers that may use the network are rejected when `requireOnDeviceProviders` is true.
