import Foundation
import Testing
@testable import Wax

// MARK: - normalizeL2InPlace

@Test func normalizeL2InPlaceProducesUnitVector() {
    var v: [Float] = [3, 4]
    VectorMath.normalizeL2InPlace(&v)
    #expect(abs(VectorMath.magnitude(v) - 1.0) < 1e-5)
    #expect(abs(v[0] - 0.6) < 1e-5)
    #expect(abs(v[1] - 0.8) < 1e-5)
}

@Test func normalizeL2InPlaceEmptyIsNoOp() {
    var v: [Float] = []
    VectorMath.normalizeL2InPlace(&v)
    #expect(v.isEmpty)
}

@Test func normalizeL2InPlaceZeroVectorIsNoOp() {
    var v: [Float] = [0, 0, 0]
    VectorMath.normalizeL2InPlace(&v)
    #expect(v == [0, 0, 0])
}

// MARK: - dotProduct

@Test func dotProductOrthogonalVectorsIsZero() {
    let a: [Float] = [1, 0, 0]
    let b: [Float] = [0, 1, 0]
    #expect(VectorMath.dotProduct(a, b) == 0)
}

@Test func dotProductParallelVectors() {
    let a: [Float] = [1, 2, 3]
    let b: [Float] = [4, 5, 6]
    // 1*4 + 2*5 + 3*6 = 32
    #expect(abs(VectorMath.dotProduct(a, b) - 32) < 1e-5)
}

@Test func dotProductEmptyVectorsIsZero() {
    #expect(VectorMath.dotProduct([], []) == 0)
}

// MARK: - cosineSimilarity

@Test func cosineSimilarityIdenticalNormalizedVectorsIsOne() {
    let v = VectorMath.normalizeL2([1, 1])
    let sim = VectorMath.cosineSimilarity(v, v)
    #expect(abs(sim - 1.0) < 1e-5)
}

@Test func cosineSimilarityOrthogonalVectorsIsZero() {
    let a: [Float] = [1, 0]
    let b: [Float] = [0, 1]
    #expect(abs(VectorMath.cosineSimilarity(a, b)) < 1e-5)
}

// MARK: - cosineSimilarityNormalized

@Test func cosineSimilarityNormalizedHandlesUnnormalizedVectors() {
    let a: [Float] = [3, 0]
    let b: [Float] = [0, 5]
    let sim = VectorMath.cosineSimilarityNormalized(a, b)
    #expect(abs(sim) < 1e-5)
}

@Test func cosineSimilarityNormalizedParallelVectorsIsOne() {
    let a: [Float] = [2, 2]
    let b: [Float] = [4, 4]
    let sim = VectorMath.cosineSimilarityNormalized(a, b)
    #expect(abs(sim - 1.0) < 1e-4)
}

// MARK: - squaredEuclideanDistance

@Test func squaredEuclideanDistanceSameVectorIsZero() {
    let v: [Float] = [1, 2, 3]
    #expect(VectorMath.squaredEuclideanDistance(v, v) < 1e-10)
}

@Test func squaredEuclideanDistanceKnownValue() {
    let a: [Float] = [0, 0]
    let b: [Float] = [3, 4]
    // 9 + 16 = 25
    #expect(abs(VectorMath.squaredEuclideanDistance(a, b) - 25) < 1e-5)
}

@Test func squaredEuclideanDistanceEmptyIsZero() {
    #expect(VectorMath.squaredEuclideanDistance([], []) == 0)
}

// MARK: - euclideanDistance

@Test func euclideanDistanceKnownValue() {
    let a: [Float] = [0, 0]
    let b: [Float] = [3, 4]
    #expect(abs(VectorMath.euclideanDistance(a, b) - 5.0) < 1e-5)
}

// MARK: - add

@Test func addElementWise() {
    let a: [Float] = [1, 2, 3]
    let b: [Float] = [4, 5, 6]
    let result = VectorMath.add(a, b)
    #expect(abs(result[0] - 5) < 1e-5)
    #expect(abs(result[1] - 7) < 1e-5)
    #expect(abs(result[2] - 9) < 1e-5)
}

@Test func addEmptyVectors() {
    #expect(VectorMath.add([], []).isEmpty)
}

// MARK: - subtract

@Test func subtractElementWise() {
    let a: [Float] = [10, 20, 30]
    let b: [Float] = [1, 2, 3]
    let result = VectorMath.subtract(a, b)
    #expect(abs(result[0] - 9) < 1e-5)
    #expect(abs(result[1] - 18) < 1e-5)
    #expect(abs(result[2] - 27) < 1e-5)
}

@Test func subtractEmptyVectors() {
    #expect(VectorMath.subtract([], []).isEmpty)
}

// MARK: - scale

@Test func scaleByFactor() {
    let v: [Float] = [1, 2, 3]
    let result = VectorMath.scale(v, by: 2)
    #expect(abs(result[0] - 2) < 1e-5)
    #expect(abs(result[1] - 4) < 1e-5)
    #expect(abs(result[2] - 6) < 1e-5)
}

@Test func scaleByZero() {
    let v: [Float] = [1, 2, 3]
    let result = VectorMath.scale(v, by: 0)
    for x in result { #expect(abs(x) < 1e-10) }
}

@Test func scaleEmptyVector() {
    #expect(VectorMath.scale([], by: 5).isEmpty)
}
