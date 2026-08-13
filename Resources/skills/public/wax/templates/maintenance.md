Template: Persistence Lifecycle (Flush / Close)
Goal: Safely persist the store.

Documented fixture tokens (snippet verifier only):
- `__WAX_STORE_URL__`

Note: Surrogate optimization and index compaction (`optimizeSurrogates`, `compactIndexes`)
are package-only maintenance APIs and are not available to downstream apps. The public
lifecycle is `flush()` and `close()`; Wax rewrites indexes automatically during commits
when needed.

A default new public store is approximately 4 MiB WAL plus committed data. Close before
any file-level copy or sync. Do not run concurrent writers across devices.

Steps:
1. Open Memory.
2. Save/search as needed.
3. Flush to force pending writes to durable storage.
4. Close (flushes automatically) when done.

Swift Skeleton:
```swift compile
import Foundation
import Wax

func templateMaintenance() async throws {
    let memory = try await Memory(at: __WAX_STORE_URL__)
    try await memory.save("Durable note.")
    try await memory.flush()
    try await memory.close()
}
```
