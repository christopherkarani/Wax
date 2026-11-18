import Foundation
import Testing
@testable import WaxVectorSearch

/// `preparedRows` as it was written before it skipped unit-length stores: every row's norm
/// summed in order, and rows not within 0.001 of unit length divided by it.
private func referencePreparedRows(_ rows: [Float], dimensions: Int) -> [Float] {
    var prepared = rows
    var start = 0
    while start < prepared.count {
        var sum: Float = 0
        for index in start..<(start + dimensions) {
            sum += prepared[index] * prepared[index]
        }
        let norm = sum.squareRoot()
        if norm > 0, !(abs(norm - 1) < 0.001) {
            for index in start..<(start + dimensions) {
                prepared[index] = prepared[index] / norm
            }
        }
        start += dimensions
    }
    return prepared
}

/// A row of `dimensions` values whose norm is `norm`.
private func row(dimensions: Int, norm: Float, seed: Int) -> [Float] {
    let raw = (0..<dimensions).map { Float(sin(Double(seed * 31 + $0) * 0.7)) }
    let length = raw.reduce(Float.zero) { $0 + $1 * $1 }.squareRoot()
    return raw.map { $0 / length * norm }
}

@Test(arguments: [3, 16, 37, 384])
func preparedRowsMatchesTheReferenceBitForBit(dimensions: Int) {
    // Unit rows, rows just inside and outside the 0.001 band, a zero row and a long row.
    let norms: [Float] = [1, 1, 1.0005, 0.9995, 1.0015, 0.9985, 0, 3, 1, 1]
    var rows: [Float] = []
    for (seed, norm) in norms.enumerated() {
        rows += row(dimensions: dimensions, norm: norm, seed: seed)
    }
    let prepared = VectorPreparation.preparedRows(rows, dimensions: dimensions, metric: .cosine)
    let expected = referencePreparedRows(rows, dimensions: dimensions)
    #expect(prepared.map(\.bitPattern) == expected.map(\.bitPattern))
}

@Test func preparedRowsLeavesUnitRowsAndOtherMetricsUntouched() {
    let unit = (0..<50).flatMap { row(dimensions: 384, norm: 1, seed: $0) }
    #expect(VectorPreparation.preparedRows(unit, dimensions: 384, metric: .cosine).map(\.bitPattern)
        == unit.map(\.bitPattern))

    let long = row(dimensions: 8, norm: 5, seed: 1)
    #expect(VectorPreparation.preparedRows(long, dimensions: 8, metric: .l2) == long)
    #expect(VectorPreparation.preparedRows(long, dimensions: 8, metric: .dot) == long)
}
