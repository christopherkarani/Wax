# Photo RAG

Understand the package-internal photo retrieval architecture.

## Status

Photo RAG types such as `PhotoRAGOrchestrator` and `PhotoRAGConfig` are
package-internal in the current Wax target. They are not external Swift API and
should not be used in public consumer snippets.

External applications that need stable public API should use ``Memory`` for
text memory today:

```swift
var config = Memory.Config()
config.enableVectorSearch = false
let memory = try await Memory(at: storeURL, config: config)

try await memory.save(
    "Photo note: whiteboard has Q4 roadmap sketch.",
    metadata: ["source": "photo-ocr"]
)

var options = Memory.SearchOptions()
options.mode = .textOnly
let context = try await memory.search("Q4 roadmap sketch", options: options)
```

## Internal Architecture

Inside Wax, each photo is represented as a hierarchy of frames:

| Frame Kind | Content |
|------------|---------|
| `root` | Photo metadata such as asset ID, capture date, camera, and GPS |
| `ocrBlock` | Individual OCR text blocks |
| `ocrSummary` | Concatenated OCR text for the full image |
| `captionShort` | Short image caption |
| `tags` | Detected tags and labels |
| `region` | Bounding box regions of interest |
| `syncState` | Library sync checkpoint |

The internal query pipeline embeds query text, searches OCR/caption text and
image embeddings, fuses results with RRF, and returns ranked photo evidence.
