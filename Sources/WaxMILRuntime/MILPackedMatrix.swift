import Dispatch
import Foundation
import WaxMILKernelsC

/// A constant `linear` weight `[n, k]`, packed once at load into the panel layout that
/// `wax_mil_sgemm_packed` reads, so inference never repacks it.
///
/// `@unchecked Sendable`: the buffer is written only in `init` and read-only afterwards.
final class MILPackedMatrix: @unchecked Sendable {
    let n: Int
    let k: Int
    private let raw: UnsafeMutableRawPointer
    private let memory: UnsafeMutablePointer<Float>

    init(weight: MILTensor) {
        precondition(weight.rank == 2)
        n = weight.shape[0]
        k = weight.shape[1]
        let count = wax_mil_sgemm_packed_b_count(n, k)
        // The micro-kernel uses aligned 32-byte loads on the panels.
        raw = UnsafeMutableRawPointer.allocate(byteCount: max(count, 1) * MemoryLayout<Float>.stride, alignment: 64)
        memory = raw.bindMemory(to: Float.self, capacity: max(count, 1))
        let (n, k, memory) = (n, k, memory)
        MILKernels.floatStorage(weight).withUnsafeBufferPointer { source in
            wax_mil_sgemm_pack_b(1, n, k, source.baseAddress, k, memory)
        }
    }

    deinit {
        raw.deallocate()
    }

    func withPanels<R>(_ body: (UnsafePointer<Float>) throws -> R) rethrows -> R {
        try withExtendedLifetime(self) { try body(UnsafePointer(memory)) }
    }
}

/// Raw pointers handed to worker threads that write disjoint regions.
struct MILSharedPointer<T>: @unchecked Sendable {
    let base: UnsafeMutablePointer<T>
}

struct MILSharedConstPointer<T>: @unchecked Sendable {
    let base: UnsafePointer<T>
}

enum MILParallel {
    /// Multiply-accumulates below which a product stays on the calling thread.
    static let minimumWorkPerThread = 1 << 20

    /// Splits `count` work items into at most `threads` contiguous chunks and runs them,
    /// concurrently when there is more than one. `body` receives a half-open item range.
    static func forEachChunk(
        of count: Int,
        threads: Int,
        _ body: @Sendable (Range<Int>) -> Void
    ) {
        let chunks = max(1, min(threads, count))
        if chunks == 1 {
            body(0..<count)
            return
        }
        DispatchQueue.concurrentPerform(iterations: chunks) { chunk in
            body((chunk * count / chunks)..<((chunk + 1) * count / chunks))
        }
    }

    /// Threads worth using for `work` multiply-accumulates.
    static func threads(forWork work: Int, maximum: Int) -> Int {
        max(1, min(maximum, work / minimumWorkPerThread))
    }
}
