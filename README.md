<!-- HEADER:START -->
<div align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="docs/assets/banner-dark.svg">
    <img src="docs/assets/banner-light.svg" width="800" alt="Wax Banner" />
  </picture>
</div>

<div style="height: 16px;"></div>

<p align="center">
  <strong>Wax is a high-performance, single-file memory layer for AI agents on Apple platforms.</strong><br/>
  On-device, private, and portable — no server, no cloud, zero infrastructure.
</p>

<p align="center">
  <a href="https://github.com/christopherkarani/Wax/releases"><img src="https://img.shields.io/github/v/release/christopherkarani/Wax?style=flat-square&logo=swift&logoColor=white&label=Swift" alt="Swift" /></a>
  <a href="https://developer.apple.com/ios/"><img src="https://img.shields.io/badge/platform-iOS%20%7C%20macOS-lightgrey?style=flat-square" alt="Platforms" /></a>
  <a href="https://github.com/christopherkarani/Wax/blob/main/LICENSE"><img src="https://img.shields.io/badge/license-Apache%202.0-blue?style=flat-square" alt="License" /></a>
  <a href="https://github.com/christopherkarani/Wax/stargazers"><img src="https://img.shields.io/github/stars/christopherkarani/Wax?style=flat-square&logo=github" alt="Stars" /></a>
</p>

<p align="center">
  [English](README.md) | [Español](locales/README.es.md) | [日本語](locales/README.ja.md) | [中文](locales/README.zh-CN.md)
</p>
<!-- HEADER:END -->

---

## Technical Summary

Wax is a Swift-native persistence engine designed for the next generation of AI agents. It encapsulates documents, high-dimensional embeddings, and structured knowledge into a single, portable `.wax` file. By leveraging Metal-accelerated inference and concurrent indexing, Wax provides a low-latency memory layer that ensures data remains private and resides strictly on the user's device.

## Key Features

- **Fast & Efficient**: Optimized for Apple Silicon with Metal-accelerated embeddings and LZ4 compression.
- **Type-Safe & Native**: A pure Swift 6 API with full support for Actors and Structured Concurrency.
- **Unified Memory**: Hybrid retrieval combining BM25 full-text search with HNSW vector similarity.
- **Single Portable File**: No external databases or sidecars. Your agent's entire memory is one `.wax` file.
- **Crash-Resilient**: Atomic writes with Write-Ahead Logging (WAL) and dual-header redundancy.

## Performance

Wax is tuned for the M-series architecture, providing near-instantaneous recall even with large-scale local indices.

Latest measured snapshot (2026-03-06):

- **Cold open p95:** `9.2 ms`
- **Warm hybrid with previews p95 / p99:** `6.1 ms / 6.5 ms`
- **MemoryOrchestrator ingest:** `0.445 s avg`
- **WAL large_hybrid_10k commit p95 / p99:** `97.40 ms / 100.30 ms`
- Full benchmark report: [docs/benchmarks/2026-03-06-performance-results.md](docs/benchmarks/2026-03-06-performance-results.md)

<div align="center">
<svg width="600" height="120" viewBox="0 0 600 120" xmlns="http://www.w3.org/2000/svg">
  <!-- Recall Latency (ms) -->
  <text x="0" y="20" font-family="system-ui" font-size="12" fill="#8E8E93">Recall Latency (ms) - Lower is better</text>
  <rect x="0" y="30" width="450" height="20" rx="4" fill="#E5E5EA" />
  <rect x="0" y="30" width="24" height="20" rx="4" fill="#007AFF" />
  <text x="30" y="44" font-family="system-ui" font-size="12" font-weight="600" fill="#1C1C1E">6.1ms p95 (Wax)</text>
  <text x="455" y="44" font-family="system-ui" font-size="12" fill="#8E8E93">vs 150ms+ (Cloud RAG)</text>

  <!-- Throughput (docs/s) -->
  <text x="0" y="80" font-family="system-ui" font-size="12" fill="#8E8E93">Ingest Throughput (docs/s) - Higher is better</text>
  <rect x="0" y="90" width="450" height="20" rx="4" fill="#E5E5EA" />
  <rect x="0" y="90" width="160" height="20" rx="4" fill="#34C759" />
  <text x="165" y="104" font-family="system-ui" font-size="12" font-weight="600" fill="#1C1C1E">85.9 docs/s (Wax)</text>
</svg>
<p><sub>Benchmark conducted on Apple M3 Max. Results vary by hardware.</sub></p>
</div>

## Quick Start

```swift
import Wax
import WaxVectorSearchMiniLM

// 1. Initialize a memory store on-device
let memory = try await MemoryOrchestrator.openMiniLM(
    at: .documentsDirectory.appending(path: "agent.wax")
)

// 2. Commit memories with async/await
try await memory.remember("The user's name is Alex and they live in Toronto.")
try await memory.remember("Alex is building a habit tracker in SwiftUI.")

// 3. Perform semantic recall
let context = try await memory.recall(query: "Where does the user live?")
if let bestMatch = context.items.first {
    print("Recall: \(bestMatch.text)") // "The user's name is Alex and they live in Toronto."
}
```

## Installation

### Swift Package Manager

```swift
dependencies: [
    .package(url: "https://github.com/christopherkarani/Wax.git", from: "0.1.8")
]
```

## MCP Server

Wax provides a first-class Model Context Protocol (MCP) server for integration with Claude Code and other MCP-compatible agents.

```bash
npx -y waxmcp@latest mcp install --scope user
```

---

## Architecture

Everything lives in a single `.wax` file with a specialized ring-buffer for crash recovery and an immutable frame-based storage model.

```
┌────────────────────────────┐
│ Dual Header Pages          │  Magic, TOC pointer
├────────────────────────────┤
│ WAL Ring Buffer             │  Atomic recovery
├────────────────────────────┤
│ Compressed Data            │  LZ4/zlib frames
├────────────────────────────┤
│ Hybrid Search Indices      │  BM25 + HNSW
└────────────────────────────┘
```

## License

Wax is released under the Apache License 2.0. See [LICENSE](LICENSE) for details.

<div align="center">
<sub>Built for developers who believe user data belongs on the user's device.</sub>
</div>
