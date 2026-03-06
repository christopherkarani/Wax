<div align="center">

# Wax

**On-device long-term memory for Swift AI apps and agents on iOS/macOS.**

<img src="https://img.shields.io/badge/Swift-6.2-F05138?style=flat&logo=swift&logoColor=white" />
<img src="https://img.shields.io/badge/platform-iOS%2018%2B%20%7C%20macOS%2015%2B-blue?style=flat&logo=apple" />
<img src="https://img.shields.io/badge/license-Apache%202.0-green?style=flat" />
<img src="https://img.shields.io/github/actions/workflow/status/christopherkarani/Wax/ci.yml?branch=main&style=flat" />

</div>

Wax is a Swift-native memory framework that stores text, metadata, and retrieval indexes in one local `.wax` file so agents can remember, search, and recall context without cloud infrastructure.

## Quick start

```swift
import Wax
import WaxVectorSearchMiniLM

let memory = try await MemoryOrchestrator.openMiniLM(
    at: .documentsDirectory.appending(path: "assistant.wax")
)

try await memory.remember("User prefers concise answers.")
let context = try await memory.recall(query: "communication preferences")

for item in context.items {
    print(item.kind, item.score, item.text)
}
```

## Installation (SPM)

```swift
// Package.swift
dependencies: [
  .package(url: "https://github.com/christopherkarani/Wax.git", from: "0.1.8")
],
targets: [
  .target(
    name: "MyApp",
    dependencies: [
      .product(name: "Wax", package: "Wax"),
      .product(name: "WaxVectorSearchMiniLM", package: "Wax")
    ]
  )
]
```

## What Wax gives you

1. **Hybrid retrieval**: BM25 text + vector similarity.
2. **On-device embeddings**: MiniLM provider with no network calls.
3. **Crash-safe persistence**: WAL + dual-header file format.
4. **RAG context building**: token-aware, ranked output for prompts.
5. **Structured memory**: entity/predicate/fact graph with temporal queries.

## Common usage patterns

### 1) Remember and recall

```swift
try await memory.remember("Alex is building a SwiftUI habit tracker")
let rag = try await memory.recall(query: "what project is Alex building?")
```

### 2) Session-aware memory

```swift
let sessionID = await memory.startSession()
try await memory.remember("Discussed onboarding flow", metadata: ["session": sessionID.uuidString])
await memory.endSession()
```

### 3) Maintenance and durability

```swift
try await memory.flush()                // force persisted commit
let stats = try await memory.runtimeStats()
print(stats.frameCount, stats.generation)
```

## When to use Wax

Use Wax when you need:
- local/private memory for iOS or macOS AI features,
- hybrid retrieval + RAG context construction,
- deterministic persistence without managing multiple storage systems.

## When not to use Wax

Wax may not be the right fit when:
- you require multi-tenant cloud hosting as the primary storage model,
- your target platform is outside Apple ecosystems,
- you only need ephemeral in-memory context with no persistence.

## MCP / CLI

Install the MCP launcher:

```bash
npx -y waxmcp@latest mcp install --scope user
```

Run locally:

```bash
swift run wax-mcp --help
swift run wax-cli --help
```

## Documentation

- Core docs: `Sources/WaxCore/WaxCore.docc`
- Orchestrator docs: `Resources/website/docs/orchestrator`
- MiniLM docs: `Sources/WaxVectorSearchMiniLM/WaxVectorSearchMiniLM.docc`

## Contributing

Contributions are welcome. Please open an issue/discussion for design changes and include tests with PRs.

## License

Apache 2.0. See [LICENSE](LICENSE).
