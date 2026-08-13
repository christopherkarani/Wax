Template: Hybrid Search (Memory)
Goal: Run hybrid search fusing text + vector signals through the public Memory facade.

Documented fixture tokens (snippet verifier only):
- `__WAX_STORE_URL__`

Steps:
1. Open Memory (built-in MiniLM is auto-wired on iOS 18/macOS 15+).
2. Search with `.hybrid(alpha:)`.
3. Check `results.diagnostics` to confirm the vector lane actually ran.

Swift Skeleton:
```swift compile
import Foundation
import Wax

func templateHybridSearch() async throws {
    let memory = try await Memory(at: __WAX_STORE_URL__)
    try await memory.save("Had coffee with Alice. She mentioned the Q4 roadmap.")

    let results = try await memory.search(
        "Alice roadmap",
        options: .init(topK: 5, mode: .hybrid(alpha: 0.7))
    )

    for item in results.items {
        print(item.text)
    }

    if let diagnostics = results.diagnostics {
        print(diagnostics.effectiveMode, diagnostics.queryEmbeddingState)
    }

    try await memory.close()
}
```
