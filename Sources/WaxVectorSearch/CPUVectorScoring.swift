import Dispatch
import Foundation
import WaxVectorSearchC

/// SIMD scoring of row-major Float32 rows against a query, for platforms without Accelerate.
///
/// Wraps the kernels in `WaxVectorSearchC/wax_vector_scores.c`: a generic kernel written with
/// vector extensions (SSE2 on x86-64, NEON on arm64, separate multiply and add) and, on
/// x86-64 CPUs with AVX2 and FMA, a fused multiply-add kernel picked at run time. Each row is
/// summed in a fixed order that does not depend on where the row is stored, so identical
/// rows tie exactly and any split of the rows gives the same scores.
package enum CPUVectorScoring {
    package enum Kernel: Sendable, Equatable, CustomStringConvertible {
        case generic
        case avx2

        fileprivate var code: Int32 {
            switch self {
            case .generic:
                return WAX_VECTOR_KERNEL_GENERIC
            case .avx2:
                return WAX_VECTOR_KERNEL_AVX2
            }
        }

        fileprivate init(code: Int32) {
            self = code == WAX_VECTOR_KERNEL_AVX2 ? .avx2 : .generic
        }

        package var description: String {
            switch self {
            case .generic:
                return "generic"
            case .avx2:
                return "avx2"
            }
        }
    }

    /// The kernel used when none is requested.
    package static var automaticKernel: Kernel {
        Kernel(code: wax_vector_kernel_resolve(WAX_VECTOR_KERNEL_AUTO))
    }

    /// Kernels this CPU runs, generic first.
    package static var availableKernels: [Kernel] {
        wax_vector_kernel_resolve(WAX_VECTOR_KERNEL_AVX2) == WAX_VECTOR_KERNEL_AVX2 ? [.generic, .avx2] : [.generic]
    }

    /// Writes one score per row into `scores`: the dot product with `query`, or with
    /// `squaredNorms`, `-(squaredNorms[row] + queryNorm - 2 * dot)` (L2), rounded step by step
    /// exactly as ``AccelerateVectorEngine`` computes it from the dot product.
    /// - Parameter kernel: `nil` picks ``automaticKernel``. A test seam.
    package static func score(
        rows: UnsafePointer<Float>,
        rowCount: Int,
        dimensions: Int,
        query: UnsafePointer<Float>,
        squaredNorms: UnsafePointer<Float>?,
        queryNorm: Float,
        into scores: UnsafeMutablePointer<Float>,
        kernel: Kernel? = nil
    ) {
        wax_vector_scores(
            kernel?.code ?? WAX_VECTOR_KERNEL_AUTO,
            rows,
            Int64(rowCount),
            Int64(dimensions),
            query,
            squaredNorms,
            queryNorm,
            scores
        )
    }

    /// Floats each parallel chunk scans at least. The scan is memory bound: one thread
    /// streams about 11 GB/s on a 4-core x86-64 VM and four about 40 GB/s, so splitting pays
    /// once a chunk is a few MB (2 MB here; 1,365 rows of 384 dims).
    package static let minimumParallelChunkElements = 1 << 19

    /// Chunks to split a scan of `rowCount` rows into: 1 (stay on the calling thread) below
    /// two chunks' worth of floats, else at most one per processor.
    package static func parallelChunkCount(
        rowCount: Int,
        dimensions: Int,
        processors: Int = ProcessInfo.processInfo.activeProcessorCount
    ) -> Int {
        let (elements, overflow) = rowCount.multipliedReportingOverflow(by: dimensions)
        let work = overflow ? Int.max : elements
        return max(1, min(processors, work / minimumParallelChunkElements))
    }

    /// One score per row of `rows` (row-major, `rowCount` x `dimensions`), as
    /// ``score(rows:rowCount:dimensions:query:squaredNorms:queryNorm:into:kernel:)`` computes
    /// it, with the rows split into `chunks` contiguous ranges scored concurrently. Every row
    /// is scored the same way in any range, so the result does not depend on `chunks`.
    ///
    /// With more than one chunk this blocks the calling thread in
    /// `DispatchQueue.concurrentPerform`: call it from a GCD thread (``BlockingWork``), not
    /// from the Swift concurrency pool.
    package static func scores(
        rows: [Float],
        rowCount: Int,
        dimensions: Int,
        query: [Float],
        squaredNorms: [Float]?,
        queryNorm: Float,
        chunks requestedChunks: Int,
        kernel: Kernel? = nil
    ) -> [Float] {
        precondition(rows.count == rowCount * dimensions, "rows must hold rowCount vectors")
        precondition(query.count == dimensions, "query width must match dimensions")
        precondition(squaredNorms.map { (norms: [Float]) -> Bool in norms.count == rowCount } ?? true, "one norm per row")
        guard rowCount > 0 else { return [] }
        let chunks = max(1, min(requestedChunks, rowCount))
        let norms = squaredNorms ?? []
        return [Float](unsafeUninitializedCapacity: rowCount) { (output: inout UnsafeMutableBufferPointer<Float>, initialized: inout Int) -> Void in
            rows.withUnsafeBufferPointer { (rowBuffer: UnsafeBufferPointer<Float>) -> Void in
                query.withUnsafeBufferPointer { (queryBuffer: UnsafeBufferPointer<Float>) -> Void in
                    norms.withUnsafeBufferPointer { (normBuffer: UnsafeBufferPointer<Float>) -> Void in
                        let scan = ChunkedScan(
                            rows: rowBuffer.baseAddress!,
                            rowCount: rowCount,
                            dimensions: dimensions,
                            query: queryBuffer.baseAddress!,
                            squaredNorms: squaredNorms == nil ? nil : normBuffer.baseAddress,
                            queryNorm: queryNorm,
                            scores: output.baseAddress!,
                            chunks: chunks,
                            kernel: kernel
                        )
                        if chunks == 1 {
                            scan.run(chunk: 0)
                        } else {
                            DispatchQueue.concurrentPerform(iterations: chunks) { (chunk: Int) -> Void in
                                scan.run(chunk: chunk)
                            }
                        }
                    }
                }
            }
            initialized = rowCount
        }
    }
}

/// One scan's chunk work, shared by the `concurrentPerform` workers.
///
/// `@unchecked Sendable`: the pointers reference buffers the caller keeps alive and
/// unmodified for the whole join, and each worker writes only its own rows' scores.
private struct ChunkedScan: @unchecked Sendable {
    let rows: UnsafePointer<Float>
    let rowCount: Int
    let dimensions: Int
    let query: UnsafePointer<Float>
    let squaredNorms: UnsafePointer<Float>?
    let queryNorm: Float
    let scores: UnsafeMutablePointer<Float>
    let chunks: Int
    let kernel: CPUVectorScoring.Kernel?

    func run(chunk: Int) {
        let first = chunk * rowCount / chunks
        let end = (chunk + 1) * rowCount / chunks
        guard first < end else { return }
        CPUVectorScoring.score(
            rows: rows + first * dimensions,
            rowCount: end - first,
            dimensions: dimensions,
            query: query,
            squaredNorms: squaredNorms.map { (norms: UnsafePointer<Float>) -> UnsafePointer<Float> in norms + first },
            queryNorm: queryNorm,
            into: scores + first,
            kernel: kernel
        )
    }
}
