import Foundation
import Testing
@testable import Wax

// MARK: - Basic get/set

@Test func memoizerBasicGetSet() async {
    let cache = EmbeddingMemoizer(capacity: 10)
    let key: UInt64 = 42
    let value: [Float] = [1.0, 2.0, 3.0]

    await cache.set(key, value: value)
    let result = await cache.get(key)
    #expect(result == value)
}

@Test func memoizerGetMissReturnsNil() async {
    let cache = EmbeddingMemoizer(capacity: 10)
    let result = await cache.get(999)
    #expect(result == nil)
}

// MARK: - LRU eviction

@Test func memoizerEvictsOldestWhenOverCapacity() async {
    let cache = EmbeddingMemoizer(capacity: 3)

    // Insert keys 1, 2, 3 (oldest = 1)
    await cache.set(1, value: [1.0])
    await cache.set(2, value: [2.0])
    await cache.set(3, value: [3.0])

    // Insert key 4; should evict key 1
    await cache.set(4, value: [4.0])

    let evicted = await cache.get(1)
    #expect(evicted == nil)

    // Keys 2, 3, 4 should survive
    #expect(await cache.get(2) == [2.0])
    #expect(await cache.get(3) == [3.0])
    #expect(await cache.get(4) == [4.0])
}

// MARK: - Capacity 0

@Test func memoizerCapacityZeroAlwaysReturnsNil() async {
    let cache = EmbeddingMemoizer(capacity: 0)
    await cache.set(1, value: [1.0])
    let result = await cache.get(1)
    #expect(result == nil)
}

@Test func memoizerCapacityZeroGetBatchReturnsEmpty() async {
    let cache = EmbeddingMemoizer(capacity: 0)
    await cache.set(1, value: [1.0])
    let results = await cache.getBatch([1, 2, 3])
    #expect(results.isEmpty)
}

// MARK: - Capacity 1

@Test func memoizerCapacityOneOnlyMostRecentSurvives() async {
    let cache = EmbeddingMemoizer(capacity: 1)

    await cache.set(1, value: [1.0])
    #expect(await cache.get(1) == [1.0])

    await cache.set(2, value: [2.0])
    #expect(await cache.get(1) == nil)
    #expect(await cache.get(2) == [2.0])
}

// MARK: - Move-to-front on get

@Test func memoizerMoveToFrontPreventsEviction() async {
    let cache = EmbeddingMemoizer(capacity: 3)

    // Insert keys 1, 2, 3
    await cache.set(1, value: [1.0])
    await cache.set(2, value: [2.0])
    await cache.set(3, value: [3.0])

    // Access key 1 to move it to front; now LRU order is 2, 3, 1
    _ = await cache.get(1)

    // Insert key 4; should evict key 2 (the oldest untouched)
    await cache.set(4, value: [4.0])

    #expect(await cache.get(1) == [1.0])
    #expect(await cache.get(2) == nil)
    #expect(await cache.get(3) == [3.0])
    #expect(await cache.get(4) == [4.0])
}

// MARK: - Update existing key

@Test func memoizerUpdateExistingKeyInPlace() async {
    let cache = EmbeddingMemoizer(capacity: 3)

    await cache.set(1, value: [1.0])
    await cache.set(2, value: [2.0])
    await cache.set(3, value: [3.0])

    // Update key 1 with new value; should not evict anything
    await cache.set(1, value: [10.0])

    #expect(await cache.get(1) == [10.0])
    #expect(await cache.get(2) == [2.0])
    #expect(await cache.get(3) == [3.0])
}

@Test func memoizerUpdateMovesToFront() async {
    let cache = EmbeddingMemoizer(capacity: 3)

    await cache.set(1, value: [1.0])
    await cache.set(2, value: [2.0])
    await cache.set(3, value: [3.0])

    // Update key 1 (moves to front); now LRU order is 2, 3, 1
    await cache.set(1, value: [10.0])

    // Insert key 4; should evict key 2 (oldest)
    await cache.set(4, value: [4.0])

    #expect(await cache.get(1) == [10.0])
    #expect(await cache.get(2) == nil)
    #expect(await cache.get(3) == [3.0])
    #expect(await cache.get(4) == [4.0])
}

// MARK: - Pointer integrity after many ops

@Test func memoizerPointerIntegrityAfterManyOperations() async {
    let cache = EmbeddingMemoizer(capacity: 5)

    // Fill cache
    for i: UInt64 in 1...5 {
        await cache.set(i, value: [Float(i)])
    }

    // Access items in various orders to exercise move-to-front
    _ = await cache.get(3)
    _ = await cache.get(1)
    _ = await cache.get(5)

    // Update middle item
    await cache.set(2, value: [20.0])

    // Force evictions by inserting beyond capacity
    await cache.set(10, value: [10.0])
    await cache.set(11, value: [11.0])

    // After all these operations the cache should still behave correctly.
    // Verify we can retrieve items that should be present and that the
    // cache does not exceed capacity. We retrieve all keys to confirm
    // no crashes or infinite loops from broken pointers.
    var presentCount = 0
    for key: UInt64 in [1, 2, 3, 4, 5, 10, 11] {
        if await cache.get(key) != nil {
            presentCount += 1
        }
    }
    #expect(presentCount == 5)
}

// MARK: - getBatch

@Test func memoizerGetBatchReturnsFoundAndTracksMisses() async {
    let cache = EmbeddingMemoizer(capacity: 10)

    await cache.set(1, value: [1.0])
    await cache.set(2, value: [2.0])
    await cache.set(3, value: [3.0])

    // Reset stats so we can measure cleanly
    await cache.resetStats()

    let results = await cache.getBatch([1, 2, 99, 100])

    #expect(results.count == 2)
    #expect(results[1] == [1.0])
    #expect(results[2] == [2.0])
    #expect(results[99] == nil)
    #expect(results[100] == nil)

    // 2 hits, 2 misses
    let rate = await cache.hitRate
    #expect(rate == 0.5)
}

// MARK: - setBatch

@Test func memoizerSetBatchInsertsMultipleItems() async {
    let cache = EmbeddingMemoizer(capacity: 10)

    let items: [(key: UInt64, value: [Float])] = [
        (1, [1.0]),
        (2, [2.0]),
        (3, [3.0]),
    ]
    await cache.setBatch(items)

    #expect(await cache.get(1) == [1.0])
    #expect(await cache.get(2) == [2.0])
    #expect(await cache.get(3) == [3.0])
}

@Test func memoizerSetBatchRespectsCapacity() async {
    let cache = EmbeddingMemoizer(capacity: 2)

    let items: [(key: UInt64, value: [Float])] = [
        (1, [1.0]),
        (2, [2.0]),
        (3, [3.0]),
        (4, [4.0]),
    ]
    await cache.setBatch(items)

    // Only the last 2 items should survive (3 and 4)
    #expect(await cache.get(1) == nil)
    #expect(await cache.get(2) == nil)
    #expect(await cache.get(3) == [3.0])
    #expect(await cache.get(4) == [4.0])
}

// MARK: - hitRate accuracy

@Test func memoizerHitRateAccuracy() async {
    let cache = EmbeddingMemoizer(capacity: 10)
    await cache.set(1, value: [1.0])

    // 3 hits
    _ = await cache.get(1)
    _ = await cache.get(1)
    _ = await cache.get(1)

    // 1 miss
    _ = await cache.get(999)

    // hitRate = 3 / 4 = 0.75
    let rate = await cache.hitRate
    #expect(rate == 0.75)
}

@Test func memoizerHitRateZeroWithNoAccesses() async {
    let cache = EmbeddingMemoizer(capacity: 10)
    let rate = await cache.hitRate
    #expect(rate == 0.0)
}

// MARK: - resetStats

@Test func memoizerResetStatsClearsCounters() async {
    let cache = EmbeddingMemoizer(capacity: 10)
    await cache.set(1, value: [1.0])

    _ = await cache.get(1) // hit
    _ = await cache.get(2) // miss

    let rateBefore = await cache.hitRate
    #expect(rateBefore == 0.5)

    await cache.resetStats()

    let rateAfter = await cache.hitRate
    #expect(rateAfter == 0.0)
}

// MARK: - EmbeddingKey.make

@Test func embeddingKeySameInputsProduceSameKey() {
    let identity = EmbeddingIdentity(provider: "test", model: "v1", dimensions: 384, normalized: true)

    let key1 = EmbeddingKey.make(text: "hello world", identity: identity, dimensions: 384, normalized: true)
    let key2 = EmbeddingKey.make(text: "hello world", identity: identity, dimensions: 384, normalized: true)

    #expect(key1 == key2)
}

@Test func embeddingKeyDifferentTextProducesDifferentKey() {
    let identity = EmbeddingIdentity(provider: "test", model: "v1", dimensions: 384, normalized: true)

    let key1 = EmbeddingKey.make(text: "hello", identity: identity, dimensions: 384, normalized: true)
    let key2 = EmbeddingKey.make(text: "world", identity: identity, dimensions: 384, normalized: true)

    #expect(key1 != key2)
}

@Test func embeddingKeyDifferentProviderProducesDifferentKey() {
    let id1 = EmbeddingIdentity(provider: "providerA", model: "v1", dimensions: 384, normalized: true)
    let id2 = EmbeddingIdentity(provider: "providerB", model: "v1", dimensions: 384, normalized: true)

    let key1 = EmbeddingKey.make(text: "hello", identity: id1, dimensions: 384, normalized: true)
    let key2 = EmbeddingKey.make(text: "hello", identity: id2, dimensions: 384, normalized: true)

    #expect(key1 != key2)
}

@Test func embeddingKeyDifferentModelProducesDifferentKey() {
    let id1 = EmbeddingIdentity(provider: "test", model: "v1", dimensions: 384, normalized: true)
    let id2 = EmbeddingIdentity(provider: "test", model: "v2", dimensions: 384, normalized: true)

    let key1 = EmbeddingKey.make(text: "hello", identity: id1, dimensions: 384, normalized: true)
    let key2 = EmbeddingKey.make(text: "hello", identity: id2, dimensions: 384, normalized: true)

    #expect(key1 != key2)
}

@Test func embeddingKeyNilIdentityProducesConsistentKey() {
    let key1 = EmbeddingKey.make(text: "hello", identity: nil, dimensions: 384, normalized: true)
    let key2 = EmbeddingKey.make(text: "hello", identity: nil, dimensions: 384, normalized: true)

    #expect(key1 == key2)
}

@Test func embeddingKeyNilVsNonNilIdentityDiffer() {
    let identity = EmbeddingIdentity(provider: "test", model: "v1", dimensions: 384, normalized: true)

    let key1 = EmbeddingKey.make(text: "hello", identity: nil, dimensions: 384, normalized: true)
    let key2 = EmbeddingKey.make(text: "hello", identity: identity, dimensions: 384, normalized: true)

    #expect(key1 != key2)
}

// MARK: - FNV1a64 deterministic hashing

@Test func fnv1a64DeterministicHashing() {
    var hasher1 = FNV1a64()
    hasher1.append("hello")
    let hash1 = hasher1.finalize()

    var hasher2 = FNV1a64()
    hasher2.append("hello")
    let hash2 = hasher2.finalize()

    #expect(hash1 == hash2)
}

@Test func fnv1a64DifferentInputsDifferentHashes() {
    var hasher1 = FNV1a64()
    hasher1.append("hello")
    let hash1 = hasher1.finalize()

    var hasher2 = FNV1a64()
    hasher2.append("world")
    let hash2 = hasher2.finalize()

    #expect(hash1 != hash2)
}

@Test func fnv1a64OrderMatters() {
    var hasher1 = FNV1a64()
    hasher1.append("ab")
    let hash1 = hasher1.finalize()

    var hasher2 = FNV1a64()
    hasher2.append("ba")
    let hash2 = hasher2.finalize()

    #expect(hash1 != hash2)
}

@Test func fnv1a64AppendOrderMatters() {
    var hasher1 = FNV1a64()
    hasher1.append("a")
    hasher1.append("b")
    let hash1 = hasher1.finalize()

    var hasher2 = FNV1a64()
    hasher2.append("b")
    hasher2.append("a")
    let hash2 = hasher2.finalize()

    #expect(hash1 != hash2)
}

@Test func fnv1a64EmptyStringProducesConsistentHash() {
    var hasher1 = FNV1a64()
    hasher1.append("")
    let hash1 = hasher1.finalize()

    var hasher2 = FNV1a64()
    hasher2.append("")
    let hash2 = hasher2.finalize()

    #expect(hash1 == hash2)
}

@Test func fnv1a64SingleAppendDiffersFromMultipleAppends() {
    // "ab" as a single append vs "a" + "b" as separate appends
    // should differ because FNV1a64.append adds a separator byte (0xFF)
    var hasher1 = FNV1a64()
    hasher1.append("ab")
    let hash1 = hasher1.finalize()

    var hasher2 = FNV1a64()
    hasher2.append("a")
    hasher2.append("b")
    let hash2 = hasher2.finalize()

    #expect(hash1 != hash2)
}
