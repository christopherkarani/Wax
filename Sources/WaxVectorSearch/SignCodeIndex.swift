import Dispatch
import Foundation
import WaxVectorSearchC

/// One-bit sign codes of a row-major vector store, used to shortlist rows for an exact
/// rescore.
///
/// Each row is kept as its sign bits (`dimensions / 8` bytes, 1/32 of the Float32 row)
/// plus its set-bit count and mean absolute value. A search quantizes the query to 4-bit
/// levels and estimates every row's dot product as `meanAbs * (query · sign(row))`, then
/// keeps the rows with the largest estimates. Callers rescore those rows exactly, so the
/// returned scores and their order are exact; the approximation is only which rows reach
/// the rescore.
package struct SignCodeIndex: Sendable {
    /// Below this width a sign code carries too little of the row to rank it.
    package static let minDimensions = 128
    /// Shortlist floor; at 100k and 1M MiniLM vectors this keeps ~0.999 of the true top 10.
    package static let minCandidates = 256
    /// Shortlist rows per requested result, for larger `topK`.
    package static let candidatesPerResult = 16
    private static let minRowsPerSlice = 25_000
    private static let maxSlices = 4

    package let dimensions: Int
    private let words: Int
    private var codes: [UInt64] = []
    private var popcounts: [UInt32] = []
    private var meanAbs: [Float] = []

    package var count: Int { popcounts.count }

    package init(dimensions: Int) {
        precondition(dimensions > 0, "dimensions must be > 0")
        self.dimensions = dimensions
        self.words = (dimensions + 63) / 64
    }

    /// Encodes every row of `rows` (row-major, `dimensions` floats per row).
    package init(dimensions: Int, rows: [Float]) {
        self.init(dimensions: dimensions)
        append(rows: rows)
    }

    /// Shortlist size for a search returning `topK` results.
    package static func candidateCount(topK: Int) -> Int {
        let (perResult, overflow) = max(topK, 1).multipliedReportingOverflow(by: candidatesPerResult)
        return overflow ? Int.max : max(minCandidates, perResult)
    }

    /// Appends rows (row-major, a whole number of rows).
    package mutating func append(rows: [Float]) {
        precondition(rows.count % dimensions == 0, "rows must hold whole vectors")
        let newRows = rows.count / dimensions
        guard newRows > 0 else { return }
        let start = count
        codes.append(contentsOf: repeatElement(0, count: newRows * words))
        popcounts.append(contentsOf: repeatElement(0, count: newRows))
        meanAbs.append(contentsOf: repeatElement(0, count: newRows))
        encode(rows, intoRowsStartingAt: start, rowCount: newRows)
    }

    /// Re-encodes row `row` from `vector`.
    package mutating func replace(row: Int, with vector: [Float]) {
        precondition(vector.count == dimensions, "vector width must match dimensions")
        precondition(row >= 0 && row < count, "row out of range")
        encode(vector, intoRowsStartingAt: row, rowCount: 1)
    }

    /// Removes `row` by moving the last row into its place (the engine's swap-remove).
    package mutating func removeSwappingLast(row: Int) {
        precondition(row >= 0 && row < count, "row out of range")
        let last = count - 1
        if row != last {
            for word in 0..<words {
                codes[row * words + word] = codes[last * words + word]
            }
            popcounts[row] = popcounts[last]
            meanAbs[row] = meanAbs[last]
        }
        codes.removeLast(words)
        popcounts.removeLast()
        meanAbs.removeLast()
    }

    /// Up to `limit` rows with the largest estimated dot product with `query`, in no
    /// particular order. Deterministic for a given store and query.
    /// - Parameter slices: Scan slices run in parallel; `nil` picks by store size and core
    ///   count. A test seam: any slice count yields the same rows.
    package func candidates(for query: [Float], limit: Int, slices requestedSlices: Int? = nil) -> [Int] {
        precondition(query.count == dimensions, "query width must match dimensions")
        let rowCount = count
        let cap = min(limit, rowCount)
        guard cap > 0 else { return [] }

        var planes = [UInt64](repeating: 0, count: Int(WAX_SIGN_CODE_QUERY_PLANES) * words)
        var a: Float = 0
        var b: Float = 0
        var c: Float = 0
        wax_sign_codes_query(query, Int64(dimensions), Int64(words), &planes, &a, &b, &c)

        let slices = max(1, min(requestedSlices ?? Self.sliceCount(rowCount: rowCount), rowCount))
        let sliceRows = (rowCount + slices - 1) / slices
        var heapScores = [Float](repeating: 0, count: cap * slices)
        var heapRows = [UInt32](repeating: 0, count: cap * slices)
        var kept = [Int](repeating: 0, count: slices)

        codes.withUnsafeBufferPointer { codeBuffer in
            popcounts.withUnsafeBufferPointer { popcountBuffer in
                meanAbs.withUnsafeBufferPointer { meanAbsBuffer in
                    planes.withUnsafeBufferPointer { planeBuffer in
                        heapScores.withUnsafeMutableBufferPointer { scoreBuffer in
                            heapRows.withUnsafeMutableBufferPointer { rowBuffer in
                                kept.withUnsafeMutableBufferPointer { keptBuffer in
                                    let scan = SliceScan(
                                        codes: codeBuffer.baseAddress!,
                                        popcounts: popcountBuffer.baseAddress!,
                                        meanAbs: meanAbsBuffer.baseAddress!,
                                        planes: planeBuffer.baseAddress!,
                                        words: words,
                                        rowCount: rowCount,
                                        sliceRows: sliceRows,
                                        cap: cap,
                                        coefficients: (a, b, c),
                                        heapScores: scoreBuffer.baseAddress!,
                                        heapRows: rowBuffer.baseAddress!,
                                        kept: keptBuffer.baseAddress!
                                    )
                                    if slices == 1 {
                                        scan.run(slice: 0)
                                    } else {
                                        DispatchQueue.concurrentPerform(iterations: slices) { slice in
                                            scan.run(slice: slice)
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }

        guard slices > 1 else {
            return heapRows.prefix(kept[0]).map { Int($0) }
        }
        // Each slice kept its own best `cap`, so the best `cap` of their union is the
        // global best `cap`.
        var mergedScores: [Float] = []
        var mergedRows: [UInt32] = []
        mergedScores.reserveCapacity(cap * slices)
        mergedRows.reserveCapacity(cap * slices)
        for slice in 0..<slices {
            let start = slice * cap
            mergedScores.append(contentsOf: heapScores[start..<(start + kept[slice])])
            mergedRows.append(contentsOf: heapRows[start..<(start + kept[slice])])
        }
        var topScores = [Float](repeating: 0, count: cap)
        var topIndices = [UInt32](repeating: 0, count: cap)
        let selected = Int(wax_top_scores(mergedScores, Int64(mergedScores.count), Int64(cap), &topScores, &topIndices))
        return topIndices.prefix(selected).map { Int(mergedRows[Int($0)]) }
    }

    private static func sliceCount(rowCount: Int) -> Int {
        let cores = ProcessInfo.processInfo.activeProcessorCount
        return max(1, min(maxSlices, cores, rowCount / minRowsPerSlice))
    }

    private mutating func encode(_ rows: [Float], intoRowsStartingAt start: Int, rowCount: Int) {
        rows.withUnsafeBufferPointer { rowBuffer in
            codes.withUnsafeMutableBufferPointer { codeBuffer in
                popcounts.withUnsafeMutableBufferPointer { popcountBuffer in
                    meanAbs.withUnsafeMutableBufferPointer { meanAbsBuffer in
                        wax_sign_codes_encode(
                            rowBuffer.baseAddress!,
                            Int64(rowCount),
                            Int64(dimensions),
                            Int64(words),
                            codeBuffer.baseAddress! + start * words,
                            popcountBuffer.baseAddress! + start,
                            meanAbsBuffer.baseAddress! + start
                        )
                    }
                }
            }
        }
    }
}

/// One search's slice work, shared by the `concurrentPerform` workers.
///
/// `@unchecked Sendable`: the pointers reference buffers the caller keeps alive and
/// unmodified for the whole join; each worker writes only its own heap region and
/// `kept` slot.
private final class SliceScan: @unchecked Sendable {
    let codes: UnsafePointer<UInt64>
    let popcounts: UnsafePointer<UInt32>
    let meanAbs: UnsafePointer<Float>
    let planes: UnsafePointer<UInt64>
    let words: Int
    let rowCount: Int
    let sliceRows: Int
    let cap: Int
    let coefficients: (a: Float, b: Float, c: Float)
    let heapScores: UnsafeMutablePointer<Float>
    let heapRows: UnsafeMutablePointer<UInt32>
    let kept: UnsafeMutablePointer<Int>

    init(
        codes: UnsafePointer<UInt64>,
        popcounts: UnsafePointer<UInt32>,
        meanAbs: UnsafePointer<Float>,
        planes: UnsafePointer<UInt64>,
        words: Int,
        rowCount: Int,
        sliceRows: Int,
        cap: Int,
        coefficients: (a: Float, b: Float, c: Float),
        heapScores: UnsafeMutablePointer<Float>,
        heapRows: UnsafeMutablePointer<UInt32>,
        kept: UnsafeMutablePointer<Int>
    ) {
        self.codes = codes
        self.popcounts = popcounts
        self.meanAbs = meanAbs
        self.planes = planes
        self.words = words
        self.rowCount = rowCount
        self.sliceRows = sliceRows
        self.cap = cap
        self.coefficients = coefficients
        self.heapScores = heapScores
        self.heapRows = heapRows
        self.kept = kept
    }

    func run(slice: Int) {
        let first = slice * sliceRows
        let end = min(rowCount, first + sliceRows)
        guard first < end else {
            kept[slice] = 0
            return
        }
        let scores = heapScores + slice * cap
        let rows = heapRows + slice * cap
        let count = Int(wax_sign_codes_scan_top(
            codes + first * words,
            popcounts + first,
            meanAbs + first,
            Int64(end - first),
            Int64(words),
            planes,
            coefficients.a,
            coefficients.b,
            coefficients.c,
            Int64(cap),
            scores,
            rows
        ))
        for index in 0..<count {
            rows[index] += UInt32(first)
        }
        kept[slice] = count
    }
}
