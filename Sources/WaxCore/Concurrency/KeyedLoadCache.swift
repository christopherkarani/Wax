import Foundation

/// A process-wide cache of expensive, synchronously loaded values, one per key.
///
/// The lock guards only the bookkeeping, never a load. A load for one key therefore never waits
/// for a load of another key, however long that takes. Callers asking for a key that is already
/// loading wait for that one load instead of starting a second. A failed load is not cached: the
/// next caller for that key loads again.
package final class KeyedLoadCache<Key: Hashable, Value>: @unchecked Sendable {
    private let condition = NSCondition()
    private var values: [Key: Value] = [:]
    private var loading: Set<Key> = []

    package init() {}

    /// Returns the cached value for `key`, calling `load` to create it on a miss.
    package func value(for key: Key, load: () throws -> Value) throws -> Value {
        condition.lock()
        while true {
            if let cached = values[key] {
                condition.unlock()
                return cached
            }
            if !loading.contains(key) { break }
            condition.wait()
        }
        loading.insert(key)
        condition.unlock()

        let result = Result { try load() }

        condition.lock()
        loading.remove(key)
        if case .success(let loaded) = result {
            values[key] = loaded
        }
        condition.broadcast()
        condition.unlock()
        return try result.get()
    }
}
