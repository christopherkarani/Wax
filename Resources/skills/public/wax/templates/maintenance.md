Template: Maintenance (Package-Internal)
Goal: Run Wax maintenance while editing the Wax package itself.

Status:
Maintenance APIs such as `optimizeSurrogates(...)`, `compactIndexes(...)`, and
the `MemoryOrchestrator` handle are package-internal in the current Wax target.
Do not use this template for external package snippets.

Public alternative:
```swift
import Foundation
import Wax

var config = Memory.Config()
config.enableVectorSearch = false
let memory = try await Memory(at: <STORE_URL>, config: config)

try await memory.save("Maintenance note")
var options = Memory.SearchOptions()
options.mode = .textOnly
let context = try await memory.search("maintenance", options: options)
_ = context.items
try await memory.close()
```

Internal implementation checklist:
1. Open the package-internal orchestrator.
2. Run surrogate optimization.
3. Compact indexes.
4. Close the handle.
