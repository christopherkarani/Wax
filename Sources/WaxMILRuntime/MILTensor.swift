import Foundation

/// Immutable Float32 storage: either owned memory or a zero-copy view of a memory-mapped
/// weight file (kept alive through `owner`).
///
/// `@unchecked Sendable`: the memory is written only inside `make(count:_:)`, before the
/// storage is returned, and is never mutated afterwards, so sharing it across threads is safe.
package final class MILFloatStorage: @unchecked Sendable {
    private let base: UnsafePointer<Float>
    package let count: Int
    private let ownedAllocation: UnsafeMutablePointer<Float>?
    private let owner: AnyObject?

    private init(base: UnsafePointer<Float>, count: Int, ownedAllocation: UnsafeMutablePointer<Float>?, owner: AnyObject?) {
        self.base = base
        self.count = count
        self.ownedAllocation = ownedAllocation
        self.owner = owner
    }

    deinit {
        ownedAllocation?.deallocate()
    }

    /// Allocates `count` floats and lets `initialize` write every element exactly once.
    package static func make(
        count: Int,
        _ initialize: (UnsafeMutableBufferPointer<Float>) throws -> Void
    ) rethrows -> MILFloatStorage {
        // At least one element so the pointer is always valid, even for empty tensors.
        let memory = UnsafeMutablePointer<Float>.allocate(capacity: max(count, 1))
        do {
            try initialize(UnsafeMutableBufferPointer(start: memory, count: count))
        } catch {
            memory.deallocate()
            throw error
        }
        return MILFloatStorage(base: UnsafePointer(memory), count: count, ownedAllocation: memory, owner: nil)
    }

    package convenience init(_ values: [Float]) {
        let memory = UnsafeMutablePointer<Float>.allocate(capacity: max(values.count, 1))
        values.withUnsafeBufferPointer { source in
            if let base = source.baseAddress {
                memory.initialize(from: base, count: values.count)
            }
        }
        self.init(base: UnsafePointer(memory), count: values.count, ownedAllocation: memory, owner: nil)
    }

    /// A view of memory that `owner` keeps alive and that nobody mutates.
    convenience init(borrowing base: UnsafePointer<Float>, count: Int, owner: AnyObject) {
        self.init(base: base, count: count, ownedAllocation: nil, owner: owner)
    }

    package func withUnsafeBufferPointer<R>(_ body: (UnsafeBufferPointer<Float>) throws -> R) rethrows -> R {
        try withExtendedLifetime(self) {
            try body(UnsafeBufferPointer(start: base, count: count))
        }
    }
}

/// A dense, row-major tensor. Floating-point tensors (fp16 or fp32) are held as Float32;
/// integer and bool tensors as Int32 (bool as 0 or 1).
package struct MILTensor: Sendable {
    package enum Storage: Sendable {
        case float(MILFloatStorage)
        case int([Int32])
    }

    package let dataType: MILDataType
    package let shape: [Int]
    package let storage: Storage

    package var count: Int { shape.reduce(1, *) }
    package var rank: Int { shape.count }

    package init(dataType: MILDataType, shape: [Int], storage: Storage) {
        self.dataType = dataType
        self.shape = shape
        self.storage = storage
    }

    package init(float32 values: [Float], shape: [Int]) {
        precondition(values.count == shape.reduce(1, *), "value count \(values.count) does not match shape \(shape)")
        self.init(dataType: .fp32, shape: shape, storage: .float(MILFloatStorage(values)))
    }

    package init(int32 values: [Int32], shape: [Int]) {
        precondition(values.count == shape.reduce(1, *), "value count \(values.count) does not match shape \(shape)")
        self.init(dataType: .int32, shape: shape, storage: .int(values))
    }

    package init(bool values: [Bool], shape: [Int]) {
        precondition(values.count == shape.reduce(1, *), "value count \(values.count) does not match shape \(shape)")
        self.init(dataType: .bool, shape: shape, storage: .int(values.map { $0 ? 1 : 0 }))
    }

    /// Whether values are held as Float32 (fp16, fp32 and widened 8-bit tensors).
    package var hasFloatStorage: Bool {
        if case .float = storage { return true }
        return false
    }

    /// Element values as Float32 (integers are converted).
    package var floats: [Float] {
        switch storage {
        case .float(let buffer): buffer.withUnsafeBufferPointer { Array($0) }
        case .int(let values): values.map { Float($0) }
        }
    }

    /// Element values as Int32 (floats are truncated toward zero, saturating).
    package var int32s: [Int32] {
        switch storage {
        case .int(let values): values
        case .float(let buffer): buffer.withUnsafeBufferPointer { $0.map(MILKernels.truncatingToInt32) }
        }
    }

    /// The same storage under a different declared type or shape with the same element count.
    func retyped(_ dataType: MILDataType, shape: [Int]? = nil) -> MILTensor {
        MILTensor(dataType: dataType, shape: shape ?? self.shape, storage: storage)
    }
}

extension MILTensor: CustomStringConvertible {
    package var description: String {
        let preview = count <= 8 ? "\(floats)" : "\(Array(floats.prefix(8)))…"
        return "tensor<\(dataType.rawValue), \(shape)> \(preview)"
    }
}
