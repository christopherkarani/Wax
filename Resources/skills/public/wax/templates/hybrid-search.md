Template: Hybrid Search (Memory)
Goal: Run hybrid search fusing text + vector signals through the public Memory facade.

Placeholders:
- <STORE_URL>
- <QUERY>
- <ALPHA>
- <TOP_K>

Steps:
1. Open Memory (built-in MiniLM is auto-wired on iOS 18/macOS 15+).
2. Search with `.hybrid(alpha:)`.
3. Check `results.diagnostics` to confirm the vector lane actually ran.

Swift Skeleton:
```swift
import Foundation
import Wax

let memory = try await Memory(at: <STORE_URL>)

let results = try await memory.search(
    <QUERY>,
    options: .init(topK: <TOP_K>, mode: .hybrid(alpha: <ALPHA>))
)

for item in results.items {
    // item.sources contains .vector when the vector lane contributed
    print(item.text)
}

if let diagnostics = results.diagnostics {
    // "hybrid(alpha=…)" when both lanes ran, "text" when the vector lane was unavailable
    print(diagnostics.effectiveMode, diagnostics.queryEmbeddingState)
}

try await memory.close()
```
