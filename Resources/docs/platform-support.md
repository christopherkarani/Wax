# Platform support

Where Wax runs, what each platform supports, and how to build it on Linux.
This page covers the Swift library, `wax-cli`, `wax-mcp` and the Hermes
provider on macOS and Linux. For iOS and iPadOS app requirements, see the
[iOS guide](../website/docs/intro.md#requirements).

## Platforms and architectures

| Platform | Architecture | Status |
|---|---|---|
| macOS 14 or later (built-in embedders need macOS 15) | arm64 (Apple Silicon) | Supported. Prebuilt `wax-cli` and `wax-mcp` ship in the `waxmcp` npm package. |
| Linux (glibc) | x86_64 | Supported, built from source. The full test suite passes on Ubuntu 24.04 with Swift 6.2. |
| Linux (glibc) | aarch64 | Not yet tested. CI jobs for it are defined but have not run yet. |
| Linux (musl, such as Alpine) | any | Not supported. |

No Linux binaries are published yet: the `waxmcp` npm package installs only on
macOS on Apple Silicon (npm refuses it elsewhere with `EBADPLATFORM`), and there
is no Homebrew formula for Linux and no container image. On Linux, build from
source as described below.

## Features by platform

| Feature | macOS (Apple Silicon) | Linux |
|---|---|---|
| `Memory` Swift API (save, search, flush, close) | Yes | Yes |
| Text search (SQLite FTS5) | Yes | Yes |
| Hybrid and vector search | Yes | Yes, on the CPU vector engine |
| e5-small-v2 embedder (default `E5Embeddings` trait) | Yes, on Core ML | Yes, on Wax's CPU interpreter |
| MiniLM embedder (default `MiniLMEmbeddings` trait) | Yes, on Core ML | Yes, on Wax's CPU interpreter |
| Arctic embedder (opt-in `ArcticEmbeddings` trait) | Yes, on Core ML | Yes, on Wax's CPU interpreter |
| MiniLM reranker (opt-in `MiniLMReranker` trait) | Yes, on Core ML | Yes, on Wax's CPU interpreter |
| `wax-cli` | Yes | Yes, built from source |
| `wax-mcp` (stdio and HTTP, `MCPServer` trait) | Yes | Yes, built from source |
| Broker daemon (one shared writer per store) | Yes | Yes |
| Hermes `wax-memory` provider | Yes | Yes, installed from a checkout |
| `wax-cli mcp doctor` | Yes | Yes, with a Linux runtime section |
| HTTP server as a login service | launchd LaunchAgent `ai.wax.mcp-http` | systemd user unit `wax-mcp-http.service` (see below) |
| PDF text ingest | Yes (PDFKit) | No |
| `PhotoMemory` / `VideoMemory` (experimental) | Yes | No: they need Apple frameworks |
| `wax-repo` (opt-in `WaxRepo` trait) | Yes | No: macOS only |
| Metal vector engine | Yes | No |
| LZFSE-compressed frames | Read and write | No |

Notes:

- **Embedders on Linux.** The built-in embedders and the reranker run the same
  bundled model files that Core ML uses on Apple platforms, on Wax's CPU
  interpreter. They record the same embedding identity, so a store written on
  one platform is searchable on the other. Linux runs them on the CPU only.
  Compute-unit options apply to Core ML and are ignored on Linux.
- **Store portability.** Wax does not write LZFSE-compressed frames by default,
  so stores written by `Memory`, `wax-cli` and `wax-mcp` open on both
  platforms. A frame compressed with LZFSE can be read only on Apple platforms.
- **Same traits for both binaries.** Build `wax-cli` and `wax-mcp` with the same
  embedder traits. If only one of them has an embedder, vector search silently
  becomes text-only.
- **Performance.** No Linux performance numbers are published. The benchmark
  results in this repository were measured on Apple Silicon.

## What is tested on Linux

These pass on Ubuntu 24.04 x86_64 with Swift 6.2, and the Linux CI workflow
runs them on every pull request:

- debug and release builds of `wax-cli` and `wax-mcp`
- the full default-trait test suite (benchmarks excluded)
- the `MCPServer` test slices (MCP server, CLI doctor and MCP process tests)
- the MiniLM, e5, Arctic and reranker inference suites
- a SIGTERM shutdown smoke test of `wax-cli` and `wax-mcp`

Not yet tested on Linux:

- aarch64 (jobs defined, not yet run)
- distributions other than Ubuntu 24.04
- running the HTTP server under systemd: the unit file's contents are checked
  by tests, but CI does not start it under systemd

## Requirements on Linux

- **Swift 6.2** or later (the package uses `swift-tools-version: 6.2` and
  package traits).
- **glibc 2.34 or later** is recommended. glibc 2.29 is the minimum for
  starting child processes in a working directory. Before 2.34, a file
  descriptor that another thread opens without close-on-exec while Wax starts
  a child process can leak into that child.
- **System packages** (Debian and Ubuntu names):

  ```bash
  sudo apt-get install -y liblz4-dev zlib1g-dev libsqlite3-dev
  ```

## Build from source on Linux

```bash
git clone https://github.com/christopherkarani/Wax.git
cd Wax
swift build -c release --product wax-cli --traits default,MCPServer
swift build -c release --product wax-mcp --traits default,MCPServer
```

The binaries land in `.build/release/` next to the `.resources` bundles that
hold the embedder models. Keep them together: Wax looks for model bundles
beside the executable.

To stage the runtime under `~/.local/share/waxmcp` (the HTTP launcher, the
operator skill and the Hermes provider copy), run the npm launcher from the
checkout, since npm does not install the package on Linux:

```bash
WAX_MCP_BIN="$PWD/.build/release/wax-mcp" \
WAX_CLI_BIN="$PWD/.build/release/wax-cli" \
node Resources/npm/waxmcp/bin/waxmcp.js install
```

The runtime goes to `~/.local/share/waxmcp/runtime/linux-x64/` (or
`linux-arm64/`). The same launcher runs the other `waxmcp` commands, for
example `node Resources/npm/waxmcp/bin/waxmcp.js install-hermes-plugin` for the
Hermes provider, and the staged `wax-cli mcp doctor` checks the install.

To keep the HTTP server running, install the systemd user unit as described in
[Connect a coding agent to Wax](wax-mcp-hosts.md#one-store-one-writer). The
unit file ships in the source tree at `Resources/systemd/wax-mcp-http.service`.
