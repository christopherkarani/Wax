# Wax Agent Instructions

## Public Repository Hygiene

This repository is the public, front-facing Wax source tree. Keep it limited to
source code, tests, release automation, product documentation, examples, and
public integration assets.

Do not commit or track:

- planning scratchpads, execution ledgers, remediation checklists, or task logs
- agent lessons, session notes, handoff notes, or private workflow rules
- marketing drafts for articles, social posts, launch copy, or prompt ideation
- screenshots, issue snapshots, browser captures, or temporary debugging images
- loose root-level analysis reports that are not part of the official docs
- customer, investor, pricing, launch, or unreleased product planning material
- `.grok/`, `.ryk/`, `.skynex/`, `.pi/`, `.opencode/`, agent config dirs
- `spec/`, `CONTEXT.md`, `AUDIT_REPORT.md`, internal reliability/execution plans
- `Resources/npm/waxmcp/dist/`, `*.tgz`, `website/node_modules/`, `__pycache__/`, `*.pyc`
- draft marketing banners (`wax-banner-*.png`, `wax-github-*.png`); keep the shipping `wax-banner.png`

Use external/private notes for working plans. If a public plan is genuinely part
of the product documentation, place it under an official docs surface and make
sure it is written as user-facing documentation, not as an internal task list.

Before committing, run:

```bash
bash Resources/scripts/quality/public_repo_hygiene.sh
```

The command should exit 0. CI runs the same gate on pull requests and `main`.

`Agents.md` and `AGENTS.md` are the same file on this volume (case-insensitive).
Edit one path.

## Change Discipline

- Keep changes scoped to the user request.
- Preserve unrelated local work and generated artifacts.
- Prefer tests or concrete verification for source changes.
- Do not stage build output, caches, screenshots, or local tool directories.

## Navigation

- Text memory facade: `Sources/Wax/Memory.swift`. Photo/video public facades: `Sources/Wax/PhotoRAG/PhotoMemory.swift`, `Sources/Wax/VideoRAG/VideoMemory.swift`.
- Public re-exports live only in `Sources/Wax/PublicAliases.swift`. Do not restore `@_exported import`.
- Package-only engines — do not generate app or docs samples against them: `MemoryOrchestrator`, `PhotoRAGOrchestrator`, `VideoRAGOrchestrator`, `WaxSession`, the `Wax` actor, `MiniLMEmbedder`. Use `Memory` / `PhotoMemory` / `VideoMemory` and `BuiltInEmbeddings.make`.
- Swift public surface source of truth: `Resources/skills/public/wax/references/public-api.md`. If `constraints.md` or the wax skill disagree, follow `public-api.md` and the Swift `public` types.
- Hermes native provider (canonical): `Resources/hermes/wax-memory-plugin`. npm ship copy: `Resources/npm/waxmcp/plugins/hermes`. Listed runtime files must stay byte-identical.
- Operator MCP playbook (using Wax, not changing it): `Claude.md` and `Resources/skills/public/wax-mcp`. Swift/framework work: `Resources/skills/public/wax`.
- Product examples are allowed once reviewed. Until `Examples/` is committed, public paste contract is README + `public-api.md` + `DocsPasteHarnessTests`.

## Public API

- `import Wax` apps use `Memory`, experimental `PhotoMemory` / `VideoMemory`, and the aliases in `PublicAliases.swift`.
- Embedder selection is `Memory.Config.embedding` (`.automatic` / `.builtIn` / `.custom`). Hybrid search degrades to text; `vectorOnly` throws. Check `RAGContext.diagnostics` / `stats()`.
- Structured memory (entities/facts) stays MCP/broker-facing, not a public Swift CRUD API.
- New public names need a `public-api.md` entry plus the docs/paste tests (`WaxPublicDocsTests`, `DocsPasteHarnessTests`, `VectorSearchDocsTests`).

## Toolchain and Verification

- Swift 6.1+ package traits. Default trait: `MiniLMEmbeddings`. Opt-in: `ArcticEmbeddings`, `MCPServer`, `WaxRepo`. Linux CI uses Swift 6.2.
- Day-to-day: `swift test --filter <TestTargetOrCase>`. MCP process tests require `--traits MCPServer`. MiniLM/Arctic suites stay skipped unless `WAX_TEST_MINILM=1` / `WAX_TEST_ARCTIC=1`.
- Do not start with unfiltered `swift test` — it pulls benches. PR gate: `bash Resources/scripts/quality/production_readiness_gates.sh full` (skips soak/burn benches).
- Linux CI (`.github/workflows/waxcore-linux.yml`) is WaxCore + Wax + `wax-cli`/`wax-mcp` with `default,MCPServer` and `swift test --filter WaxCoreTests`. It is not a full Apple/integration proof. Never add `-DGRDBCUSTOMSQLITE`.
- After Linux workflow edits: `bash Resources/scripts/quality/linux_ci_workflow_tests.sh`. After Hermes plugin edits: `bash Resources/scripts/quality/hermes_plugin_tests.sh`.
- Linux `Package.swift` excludes Darwin-only integration files via `waxIntegrationLinuxExcludes`; keep that list honest (`PackageTraitManifestTests`).
- This package is SwiftPM. Do not start library work in XcodeBuildMCP unless the task is `Examples/WaxHNDemo`.

## Hermes MemoryProvider

- Exclusive backend: `memory.provider: wax-memory`. Do not add `wax-memory` to `plugins.enabled`.
- Current contract: local `is_available()`, background `sync_turn` / `queue_prefetch`, `on_session_switch`, `on_memory_write`, `recall_status`, `backup_paths`. Narrow test: `python3 -m unittest discover -s Resources/hermes/wax-memory-plugin/tests -p 'test_*.py'`.
- Vector search silently becomes text-only if only one of `wax-cli` / `wax-mcp` is built with embedder traits. Build both with `MiniLMEmbeddings` (and `MCPServer` for the server).

## Risk Areas

- Dual Hermes trees drift unless `hermes_plugin_tests.sh` is green.
- Public docs that name package-only types fail `DocsPasteHarnessTests` / `WaxPublicDocsTests`.
- Video RAG does not transcribe and does not store media bytes; the host supplies transcripts.
- Photos iCloud-only assets are metadata-only / degraded.
- Broker start timeout default is `WAX_BROKER_START_TIMEOUT_SECS=10`; do not drop it back to 5s (parallel process tests).
