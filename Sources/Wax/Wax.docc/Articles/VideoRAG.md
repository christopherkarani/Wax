# Video RAG

Understand the package-internal video retrieval architecture.

## Status

Video RAG types such as `VideoRAGOrchestrator`, `VideoRAGConfig`,
`VideoTranscriptProvider`, and `VideoQuery` are package-internal in the current
Wax target. They are not external Swift API and should not be used in public
consumer snippets.

External applications that need stable public API should use ``Memory`` for
text memory today:

```swift
var config = Memory.Config()
config.enableVectorSearch = false
let memory = try await Memory(at: storeURL, config: config)

try await memory.save(
    "Video note: architecture decision was discussed at 12:30.",
    metadata: ["source": "video-transcript"]
)

var options = Memory.SearchOptions()
options.mode = .textOnly
let context = try await memory.search("architecture decision", options: options)
```

## Internal Architecture

Inside Wax, each video is represented as a hierarchy of frames:

| Frame Kind | Content |
|------------|---------|
| `root` | Video metadata such as source, duration, and capture date |
| `segment` | Time-windowed segment with transcript and keyframe embedding |

Segments are created with configurable duration and overlap so internal queries
can pinpoint moments in long videos.

The internal query pipeline embeds query text, searches transcript text and
visual segment embeddings, fuses results with RRF, and groups evidence by source
video.
