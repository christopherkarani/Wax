# Prompt: Generalize `EmbeddingMemoizer` into a Generic Actor-Isolated LRU Cache

## Context

`Sources/Wax/Embeddings/EmbeddingMemoizer.swift` contains a hand-rolled actor-isolated LRU cache with O(1) get/set/eviction via a doubly-linked list over a dictionary. It is currently hardcoded to `UInt64` keys and `[Float]` values — serving only the embedding memoization use case.

Meanwhile, `Sources/Wax/RAG/NativeBpeTokenizer.swift:20-30` contains `LockedCache<Key: Hashable & Sendable, Value: Sendable>`, a simpler generic cache (no LRU, no capacity bound) using `OSAllocatedUnfairLock`. These two caches solve overlapping problems with different tradeoffs.

The Wax codebase has several emerging caching needs beyond embeddings:

- Query embedding caches (`EmbeddingMemoizer` instances in `PhotoRAGOrchestrator`, `VideoRAGOrchestrator`, `MemoryOrchestrator`)
- BPE token caches (`LockedCache<Data, [UInt32]>` in `NativeBpeTokenizer`)
- Potential future: `Float16` image embedding caches, caption caches, OCR result caches

## Goal

Extract `EmbeddingMemoizer` into a generic `ActorLRUCache<Key, Value>` that preserves the existing O(1) doubly-linked-list LRU implementation while becoming reusable across the framework.

## Current Implementation to Generalize

```swift
// Sources/Wax/Embeddings/EmbeddingMemoizer.swift
actor EmbeddingMemoizer {
    private struct Entry {
        var key: UInt64
        var value: [Float]
        var prev: UInt64?   // ← linked-list pointers use UInt64 (same type as key)
        var next: UInt64?
    }

    private let capacity: Int
    private var entries: [UInt64: Entry]
    private var head: UInt64?
    private var tail: UInt64?
    private var hits: UInt64 = 0
    private var misses: UInt64 = 0

    func get(_ key: UInt64) -> [Float]?
    func getBatch(_ keys: [UInt64]) -> [UInt64: [Float]]
    func set(_ key: UInt64, value: [Float])
    func setBatch(_ items: [(key: UInt64, value: [Float])])
    var hitRate: Double { get }
    func resetStats()
}
```

## Target Design

```swift
// Sources/WaxCore/Concurrency/ActorLRUCache.swift  (or Sources/Wax/Utilities/)
public actor ActorLRUCache<Key: Hashable & Sendable, Value: Sendable> {
    private struct Entry {
        var key: Key
        var value: Value
        var prev: Key?
        var next: Key?
    }

    private let capacity: Int
    private var entries: [Key: Entry]
    private var head: Key?
    private var tail: Key?
    private var hits: UInt64 = 0
    private var misses: UInt64 = 0

    public init(capacity: Int) {
        self.capacity = max(0, capacity)
        self.entries = Dictionary(minimumCapacity: capacity)
    }

    public func get(_ key: Key) -> Value?
    public func getBatch(_ keys: [Key]) -> [Key: Value]
    public func set(_ key: Key, value: Value)
    public func setBatch(_ items: [(key: Key, value: Value)])
    public var hitRate: Double { get }
    public func resetStats()

    // New: expose count for diagnostics
    public var count: Int { entries.count }
}
```

Then `EmbeddingMemoizer` becomes a typealias or thin wrapper:

```swift
// Option A: Typealias (if no embedding-specific logic needed)
typealias EmbeddingMemoizer = ActorLRUCache<UInt64, [Float]>

// Option B: Thin wrapper (if you want to keep the name stable for call sites)
actor EmbeddingMemoizer {
    private let cache: ActorLRUCache<UInt64, [Float]>

    init(capacity: Int) { cache = ActorLRUCache(capacity: capacity) }

    func get(_ key: UInt64) -> [Float]? { await cache.get(key) }
    // ... delegate all methods
}
```

## Constraints & Considerations

### 1. `Key` as linked-list pointer

The current implementation uses `Key` values (`UInt64`) as prev/next pointers in the doubly-linked list. This works for any `Hashable` key but means the linked-list nodes are keyed, not indexed. This is fine — it's the existing design and has O(1) characteristics through the dictionary lookup. Preserve this.

### 2. Actor isolation overhead

Every `get`/`set` is an `await` hop. For the BPE cache in `NativeBpeTokenizer`, the current `OSAllocatedUnfairLock`-based `LockedCache` has ~5ns acquisition vs ~1-2μs for actor hop. **Do not replace `LockedCache` with `ActorLRUCache`** — the BPE cache is on an extremely hot path (called per-token during tokenization). The generic LRU cache is appropriate for embedding-scale operations (one hop per query/chunk), not per-token operations.

### 3. `Sendable` bounds

Both `Key` and `Value` must be `Sendable` since they cross actor boundaries. `UInt64` and `[Float]` are already `Sendable`. Future uses like `String` keys or `[Float16]` values would also be `Sendable`. Add the constraint explicitly: `Key: Hashable & Sendable, Value: Sendable`.

### 4. Module placement

If placed in `WaxCore`, it becomes available to all modules. If placed in `Sources/Wax/Utilities/`, only the `Wax` module can use it. Choose based on whether `WaxVectorSearch` or `WaxTextSearch` would ever need an LRU cache. Currently they don't, so `Sources/Wax/Utilities/` is fine to start.

### 5. Batch API

Preserve `getBatch`/`setBatch`. These reduce actor hop overhead by amortizing a single isolation crossing over N operations. This is the main performance advantage over N individual `get`/`set` calls.

### 6. No `@unchecked Sendable`

The actor provides isolation. No need for lock-based `@unchecked Sendable`. This is cleaner than `LockedCache`.

### 7. Capacity = 0 semantics

Current code treats `capacity <= 0` as "caching disabled" (all operations short-circuit to nil/noop). Preserve this — it lets callers disable caching by passing `capacity: 0` without nil-checking the cache.

## What NOT To Do

- **Don't make `EmbeddingMemoizer` generic in-place.** Extract a new type and make `EmbeddingMemoizer` a consumer of it. This keeps the diff minimal and avoids touching every call site.
- **Don't replace `LockedCache`** in `NativeBpeTokenizer`. Different performance profile, different use case. The generic LRU cache is not a universal replacement for all caches.
- **Don't add eviction callbacks, TTL, or weighted eviction.** YAGNI. The LRU policy is sufficient for all current and foreseeable Wax use cases. If Wax ever needs TTL or weighted eviction, design it then.
- **Don't add `Codable` conformance** to the cache. It's ephemeral, in-memory, per-session state. Persistence is handled by the Wax store itself.

## Validation Criteria

1. All existing `EmbeddingMemoizer` tests pass without modification (or with only typealias/import changes)
2. `ActorLRUCache<String, Data>` compiles and works (proves generality)
3. No performance regression in embedding cache hit/miss paths — benchmark `getBatch` with 100 keys at capacity 512
4. `capacity: 0` still disables caching (returns nil, no allocations)
5. `swift build` succeeds with zero warnings under strict concurrency

## TDD Test Outline

```swift
// Tests/WaxCoreTests/ActorLRUCacheTests.swift (or WaxTests/)
@Test func getReturnsNilForMiss()
@Test func setAndGetRoundTrip()
@Test func evictsLRUWhenOverCapacity()
@Test func recentAccessPreventsEviction()
@Test func zeroCapacityDisablesCaching()
@Test func getBatchReturnsPartialHits()
@Test func setBatchInsertsMultiple()
@Test func hitRateTracksCorrectly()
@Test func resetStatsClearsCounters()
@Test func worksWithStringKeys()       // proves generic Key
@Test func worksWithDataValues()        // proves generic Value
@Test func concurrentAccessIsSafe()     // actor isolation smoke test
```

## Migration Path

1. Create `ActorLRUCache<Key, Value>` with full test suite
2. Make `EmbeddingMemoizer` a typealias: `typealias EmbeddingMemoizer = ActorLRUCache<UInt64, [Float]>`
3. Verify all existing tests pass
4. If any call sites break due to access level changes, add `internal` convenience extensions
5. Future: use `ActorLRUCache<String, String>` for caption caches, `ActorLRUCache<UInt64, [Float16]>` for half-precision embeddings, etc.

---

*Trigger condition: This refactor becomes actionable when a second caching use case with different key/value types emerges in Wax (e.g., caption caching, OCR result caching, or Float16 embedding support). Until then, the concrete `EmbeddingMemoizer` is the right abstraction.*
