import Foundation
import Testing
import WaxMILKernelsC

struct MILGemmTests {
    struct Case: Sendable, CustomStringConvertible {
        var m: Int, n: Int, k: Int
        var transA: Bool, transB: Bool
        var accumulate: Bool
        var description: String { "\(m)x\(n)x\(k) tA=\(transA) tB=\(transB) acc=\(accumulate)" }
    }

    /// Edge sizes around the 6 x 16 register tile and the 96 / 256 / 512 cache blocks.
    static let cases: [Case] = {
        let shapes = [(1, 1, 1), (7, 17, 5), (6, 16, 256), (13, 33, 300), (97, 20, 257), (5, 513, 3), (130, 384, 384)]
        return shapes.enumerated().flatMap { index, shape in
            [(false, false), (false, true), (true, false), (true, true)].map { transA, transB in
                Case(m: shape.0, n: shape.1, k: shape.2, transA: transA, transB: transB, accumulate: index % 2 == 1)
            }
        }
    }()

    @Test(arguments: cases)
    func matchesADoublePrecisionReference(_ c: Case) {
        var rng = SplitMix64(seed: UInt64(c.m * 1_000_003 + c.n * 1009 + c.k))
        // Leading dimensions larger than the logical width, to check strides.
        let lda = (c.transA ? c.m : c.k) + 3
        let ldb = (c.transB ? c.k : c.n) + 2
        let ldc = c.n + 5
        let a = rng.floats((c.transA ? c.k : c.m) * lda)
        let b = rng.floats((c.transB ? c.n : c.k) * ldb)
        let initial = rng.floats(c.m * ldc)
        // With beta = 0 the output must be overwritten even if it holds NaN.
        var out = c.accumulate ? initial : [Float](repeating: .nan, count: c.m * ldc)
        for i in 0..<c.m { for j in c.n..<ldc { out[i * ldc + j] = 42 } }

        wax_mil_sgemm(c.transA ? 1 : 0, c.transB ? 1 : 0, c.m, c.n, c.k, a, lda, b, ldb, c.accumulate ? 1 : 0, &out, ldc)

        var worst: Double = 0
        for i in 0..<c.m {
            for j in 0..<c.n {
                var sum = c.accumulate ? Double(initial[i * ldc + j]) : 0
                for p in 0..<c.k {
                    let av = c.transA ? a[p * lda + i] : a[i * lda + p]
                    let bv = c.transB ? b[j * ldb + p] : b[p * ldb + j]
                    sum += Double(av) * Double(bv)
                }
                worst = max(worst, abs(sum - Double(out[i * ldc + j])))
            }
            for j in c.n..<ldc {
                #expect(out[i * ldc + j] == 42, "wrote outside the \(c.n)-column block")
            }
        }
        // Float32 accumulation over k terms of magnitude <= 1.
        #expect(worst <= 1e-6 * Double(c.k) + 1e-6, "\(c): max |diff| \(worst)")
    }

    /// A pre-packed B gives bit-identical results to on-the-fly packing, and disjoint
    /// NR-aligned column ranges (how linear layers are split across threads) cover C exactly.
    @Test(arguments: [(5, 40, 7, false), (33, 600, 300, true), (1, 1536, 384, true), (97, 17, 513, false)])
    func packedColumnRangesMatchTheUnpackedKernel(m: Int, n: Int, k: Int, transB: Bool) {
        var rng = SplitMix64(seed: UInt64(m * 31 + n * 7 + k))
        let a = rng.floats(m * k)
        let b = rng.floats(n * k)
        let ldb = transB ? k : n
        var expected = [Float](repeating: 0, count: m * n)
        wax_mil_sgemm(0, transB ? 1 : 0, m, n, k, a, k, b, ldb, 0, &expected, n)

        var packed = [Float](repeating: .nan, count: wax_mil_sgemm_packed_b_count(n, k) + 16)
        // The micro-kernel needs 32-byte-aligned panels; start at the first aligned element.
        let actual = packed.withUnsafeMutableBufferPointer { buffer -> [Float] in
            let raw = UInt(bitPattern: buffer.baseAddress!)
            let base = buffer.baseAddress! + Int((64 - raw % 64) % 64) / MemoryLayout<Float>.stride
            wax_mil_sgemm_pack_b(transB ? 1 : 0, n, k, b, ldb, base)
            var out = [Float](repeating: .nan, count: m * n)
            let nr = Int(WAX_MIL_SGEMM_NR)
            let cuts = [0, nr, 3 * nr, n].map { min($0, n) }
            for (lo, hi) in zip(cuts, cuts.dropFirst()) where lo < hi {
                wax_mil_sgemm_packed(0, m, n, k, a, k, base, lo, hi, 0, &out, n)
            }
            return out
        }
        #expect(actual == expected)
    }

    @Test func zeroInnerDimensionClearsOrKeepsTheOutput() {
        var out: [Float] = [1, 2, 3, 4]
        wax_mil_sgemm(0, 0, 2, 2, 0, nil, 1, nil, 1, 1, &out, 2)
        #expect(out == [1, 2, 3, 4])
        wax_mil_sgemm(0, 0, 2, 2, 0, nil, 1, nil, 1, 0, &out, 2)
        #expect(out == [0, 0, 0, 0])
    }
}
