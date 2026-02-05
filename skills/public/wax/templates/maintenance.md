Template: Maintenance (Optimize / Compact / Flush / Close)
Goal: Run maintenance tasks and safely persist the store.

Placeholders:
- <STORE_URL>
- <EMBEDDER_TYPE>
- <MAINTENANCE_OPTIONS>

Steps:
1. Open MemoryOrchestrator (read-write).
2. Run surrogate optimization.
3. Compact indexes.
4. Flush and close.

Swift Skeleton:
```swift
import Foundation
import Wax

let storeURL = <STORE_URL>
let orchestrator = try await MemoryOrchestrator(
    at: storeURL,
    config: .default,
    embedder: <EMBEDDER_TYPE>()
)

let options = <MAINTENANCE_OPTIONS>
let surrogateReport = try await orchestrator.optimizeSurrogates(options: options)
let compactReport = try await orchestrator.compactIndexes(options: options)
_ = (surrogateReport, compactReport)

try await orchestrator.flush()
try await orchestrator.close()
```
