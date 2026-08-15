# App integration notes

Read before the first App Store–bound or multi-target build.

## Bundle size and SPM traits

- `swift-tools-version: 6.1` with package **traits**.
- Default trait `MiniLMEmbeddings` ships ~44 MB CoreML resources.
- Disable the trait only when you intentionally want text-only and tooling supports trait configuration.
- SPM also resolves transitive packages (GRDB, MetalANNS, …); only linked products enter the binary.

## Store locking

- Exclusive advisory `flock` on the `.wax` file.
- Second open on the same URL → `WaxError.lockUnavailable`.
- Unsafe to share one live store across app + widget / App Group processes.
- Use a distinct preview path when `XCODE_RUNNING_FOR_PREVIEWS=1`.

## Paths and backup

- Prefer Application Support + **bundle identifier** subdirectory.
- Create the parent directory before `Memory(at:)`.
- Large regenerable indexes: consider `URLResourceValues.isExcludedFromBackupKey = true`.
- Documents when the user should see/share the file.

## On-device providers

- `requireOnDeviceProviders` defaults to `true`.
- Custom providers rejected at open when `executionMode` is `.mayUseNetwork` unless you set `requireOnDeviceProviders = false`.

## Embedder swaps and missing embedder

- If the new embedder’s `identity` disagrees with the store binding → **open throws** `WaxError.io("memory binding mismatch…")`. Use a new file or re-ingest.
- If `identity` is `nil`, binding checks are skipped (possible silent mixing — avoid).
- Fresh store + no embedder → vector search auto-disables (text-only).
- **Existing vector index + no embedder** → open succeeds with `vectorSearchEnabled == true`, then **`save` throws `WaxError.missingEmbedder`**. Mitigate with `enableVectorSearch = false`, provide an embedder, or gate writes on `stats()`.

## Open cost

- FTS materializes via the temp directory; cost grows with corpus size.
- First MiniLM load may compile CoreML once; keep one long-lived handle.

## Errors at the UI boundary

| When | Error |
|------|--------|
| Second open / lock | `WaxError.lockUnavailable` |
| `save` with vector on, no embedder | `WaxError.missingEmbedder` |
| Forced `.builtIn` unavailable | `BuiltInEmbeddingProviderError.unavailable` |
| `.vectorOnly` without vector lane | `WaxError.io(...)` (string payload) |
| Embedder identity mismatch | `WaxError.io("memory binding mismatch…")` |

## Foundation Models (iOS 26 / macOS 26+)

Full how-to: `references/foundation-models.md`.

Optional `Memory` helpers for on-device model tools/sessions — skip unless deployment target is 26+. Still obey store locking and flush-on-background rules.

## Photo / video / structured memory

Not app APIs via `import Wax`. Do not generate orchestrator client code.
