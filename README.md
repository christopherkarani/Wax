<div align="center">

# Wax

**On-device long-term memory for Swift AI agents on iOS and macOS.**

<img src="https://img.shields.io/badge/Swift-6.2-F05138?style=flat&logo=swift&logoColor=white" alt="Swift 6.2" />
<img src="https://img.shields.io/badge/platform-iOS%2018%2B%20%7C%20macOS%2015%2B-blue?style=flat&logo=apple" alt="Platforms" />
<img src="https://img.shields.io/badge/license-Apache%202.0-green?style=flat" alt="License" />
<img src="https://img.shields.io/github/actions/workflow/status/christopherkarani/Wax/ci.yml?branch=main&style=flat" alt="CI" />

</div>

Wax gives your agent persistent, searchable memory in a single local `.wax` file—no server and no cloud dependency required.

## Quick Start

```swift
import Wax
import WaxVectorSearchMiniLM

let memory = try await MemoryOrchestrator.openMiniLM(
    at: .documentsDirectory.appending(path: "agent.wax")
)

try await memory.remember("User prefers concise answers.")
let context = try await memory.recall(query: "user communication style")
print(context.items.map(\.text))
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

## What Wax Can Do

1. **Remember** text, metadata, and relationships across app launches.
2. **Recall** with hybrid retrieval (keyword + vector) and RAG-friendly context shaping.
3. **Operate fully on-device** with crash-safe persistence and predictable token budgets.
4. **Support multimodal pipelines** via PhotoRAG and VideoRAG orchestration layers.

## When to Use Wax

Use Wax when you need:
- On-device memory for AI assistants.
- A Swift-native API for RAG and retrieval.
- Privacy-first data handling with no mandatory backend.
- A single-file portable memory store.

## When Not to Use Wax

Wax may not be the best fit when you need:
- Shared, multi-tenant, server-hosted vector infra.
- Cross-platform support outside modern Apple OS releases.
- Distributed indexing/search across many machines.

## Core API

```swift
public actor MemoryOrchestrator {
    public func remember(_ content: String, metadata: [String: String] = [:]) async throws
    public func recall(query: String) async throws -> RAGContext
    public func flush() async throws
}
```

## Documentation

- [Wax docs](Sources/Wax/Wax.docc)
- [WaxCore docs](Sources/WaxCore/WaxCore.docc)
- [Vector Search docs](Sources/WaxVectorSearch/WaxVectorSearch.docc)
- [MiniLM docs](Sources/WaxVectorSearchMiniLM/WaxVectorSearchMiniLM.docc)
- [Website docs](Resources/website/docs)

## MCP Installer (npm)

```bash
npx -y waxmcp@latest mcp install --scope user
```

## Requirements

| Requirement | Minimum |
|---|---|
| Swift | 6.2 |
| Xcode | 16.0 |
| iOS | 18.0 |
| macOS | 15.0 |

## Contributing

Contributions are welcome. Please open an issue/discussion first for major changes.

- [Contributing Guide](CONTRIBUTING.md)

## License

Wax is available under the Apache 2.0 license. See [LICENSE](LICENSE).
