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
}
