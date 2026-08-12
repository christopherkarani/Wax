Template: Persistence Lifecycle (Flush / Close)
Goal: Safely persist the store.

Placeholders:
- <STORE_URL>

Note: Surrogate optimization and index compaction (`optimizeSurrogates`, `compactIndexes`)
are package-only maintenance APIs and are not available to downstream apps. The public
lifecycle is `flush()` and `close()`; Wax rewrites indexes automatically during commits
when needed.

Steps:
1. Open Memory.
2. Save/search as needed.
3. Flush to force pending writes to durable storage.
4. Close (flushes automatically) when done.

Swift Skeleton:
```swift
import Foundation
import Wax

let memory = try await Memory(at: <STORE_URL>)

// ... save/search ...

try await memory.flush()   // commit pending WAL + indexes now
try await memory.close()   // flush + close
```
