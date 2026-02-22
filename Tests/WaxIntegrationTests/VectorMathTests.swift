import Testing
import Wax

@Test
func vectorMathNormalizationHandlesEmptyAndZeroVectors() {
    #expect(VectorMath.normalizeL2([]).isEmpty)
    #expect(VectorMath.normalizeL2([0, 0, 0]) == [0, 0, 0])

    var inPlaceEmpty: [Float] = []
    VectorMath.normalizeL2InPlace(&inPlaceEmpty)
    #expect(inPlaceEmpty.isEmpty)

    var inPlaceZero: [Float] = [0, 0]
    VectorMath.normalizeL2InPlace(&inPlaceZero)
    #expect(inPlaceZero == [0, 0])
}

@Test
func vectorMathNormalizationAndMagnitudeAreConsistent() {
    let input: [Float] = [3, 4]
    let normalized = VectorMath.normalizeL2(input)

    #expect(normalized.count == 2)
    #expect(abs(VectorMath.magnitude(normalized) - 1.0) < 1e-5)
    #expect(VectorMath.isNormalizedL2(normalized))
    #expect(!VectorMath.isNormalizedL2([]))

    var inPlace = input
    VectorMath.normalizeL2InPlace(&inPlace)
    #expect(abs(VectorMath.magnitude(inPlace) - 1.0) < 1e-5)
}

@Test
func vectorMathDotCosineAndDistanceMatchKnownValues() {
    let a: [Float] = [1, 2, 3]
    let b: [Float] = [4, 5, 6]

    #expect(abs(VectorMath.dotProduct(a, b) - 32) < 1e-5)
    #expect(abs(VectorMath.cosineSimilarity(a, b) - 32) < 1e-5)

    let normalizedCosine = VectorMath.cosineSimilarityNormalized([1, 0], [0, 1])
    #expect(abs(normalizedCosine) < 1e-5)

    #expect(abs(VectorMath.squaredEuclideanDistance([1, 2], [4, 6]) - 25) < 1e-5)
    #expect(abs(VectorMath.euclideanDistance([1, 2], [4, 6]) - 5) < 1e-5)
}

@Test
func vectorMathAddSubtractScaleAndEmptyBehaviors() {
    let a: [Float] = [1, 2, 3]
    let b: [Float] = [4, 5, 6]

    #expect(VectorMath.add(a, b) == [5, 7, 9])
    #expect(VectorMath.subtract(b, a) == [3, 3, 3])
    #expect(VectorMath.scale(a, by: 2) == [2, 4, 6])

    #expect(VectorMath.add([], []).isEmpty)
    #expect(VectorMath.subtract([], []).isEmpty)
    #expect(VectorMath.scale([], by: 2).isEmpty)
}

// MARK: - Phase 7D: additional VectorMath branch coverage

@Test
func vectorMathNormalizeSingleElementVector() {
    // A single positive element: the normalised result must be exactly 1.0.
    let result = VectorMath.normalizeL2([5.0])
    #expect(result.count == 1)
    #expect(abs(result[0] - 1.0) < 1e-6)

    // A single negative element: normalised result must be exactly -1.0.
    let negResult = VectorMath.normalizeL2([-3.0])
    #expect(negResult.count == 1)
    #expect(abs(negResult[0] - (-1.0)) < 1e-6)
}

@Test
func vectorMathNormalizeAlreadyNormalizedVectorIsIdempotent() {
    // A unit vector fed through normalizeL2 must remain unit length.
    let unit: [Float] = [1.0, 0.0, 0.0]
    let result = VectorMath.normalizeL2(unit)
    #expect(abs(VectorMath.magnitude(result) - 1.0) < 1e-5)
    // Components must be unchanged (within float precision).
    #expect(abs(result[0] - 1.0) < 1e-5)
    #expect(abs(result[1]) < 1e-5)
    #expect(abs(result[2]) < 1e-5)
}

@Test
func vectorMathNormalizeInPlaceSingleElement() {
    var v: [Float] = [7.0]
    VectorMath.normalizeL2InPlace(&v)
    #expect(abs(v[0] - 1.0) < 1e-6)
}

@Test
func vectorMathMagnitudeOfZeroVectorIsZero() {
    #expect(VectorMath.magnitude([0.0, 0.0, 0.0]) == 0.0)
}

@Test
func vectorMathMagnitudeOfEmptyVectorIsZero() {
    #expect(VectorMath.magnitude([]) == 0.0)
}

@Test
func vectorMathIsNormalizedL2ToleranceBoundary() {
    // A vector whose magnitude deviates by exactly the default tolerance (1e-3)
    // is considered normalized; deviation just beyond it is not.
    let onBoundary: [Float] = [1.0 + 1e-3, 0.0]
    // magnitude ≈ 1.001 → |mag - 1| = 0.001 → borderline pass (default tolerance 1e-3 is inclusive)
    #expect(VectorMath.isNormalizedL2(onBoundary, tolerance: 1e-3))

    // magnitude = 1.002 → |mag - 1| ≈ 0.002 > 1e-3 → must fail
    let overBoundary: [Float] = [1.002, 0.0]
    #expect(!VectorMath.isNormalizedL2(overBoundary, tolerance: 1e-3))
}

@Test
func vectorMathCosineSimilarityOfAntiparallelVectorsIsNegativeOne() {
    // Fully opposite unit vectors: cosine similarity = -1.
    let sim = VectorMath.cosineSimilarityNormalized([1.0, 0.0], [-1.0, 0.0])
    #expect(abs(sim - (-1.0)) < 1e-5)
}

@Test
func vectorMathCosineSimilarityNormalizedOfParallelVectorsIsOne() {
    let sim = VectorMath.cosineSimilarityNormalized([3.0, 4.0], [3.0, 4.0])
    // Both vectors are the same → cosine = 1.
    #expect(abs(sim - 1.0) < 1e-5)
}

@Test
func vectorMathSquaredEuclideanDistanceOfIdenticalVectorsIsZero() {
    let d = VectorMath.squaredEuclideanDistance([1.0, 2.0, 3.0], [1.0, 2.0, 3.0])
    #expect(d == 0.0)
}

@Test
func vectorMathEuclideanDistanceOfEmptyVectorsIsZero() {
    #expect(VectorMath.squaredEuclideanDistance([], []) == 0.0)
    #expect(VectorMath.euclideanDistance([], []) == 0.0)
}

@Test
func vectorMathDotProductOfEmptyVectorsIsZero() {
    #expect(VectorMath.dotProduct([], []) == 0.0)
}

@Test
func vectorMathScaleByZeroProducesZeroVector() {
    let result = VectorMath.scale([1.0, 2.0, 3.0], by: 0.0)
    #expect(result == [0.0, 0.0, 0.0])
}

@Test
func vectorMathScaleByNegativeOneNegatesComponents() {
    let result = VectorMath.scale([1.0, -2.0, 3.0], by: -1.0)
    #expect(abs(result[0] - (-1.0)) < 1e-6)
    #expect(abs(result[1] - 2.0) < 1e-6)
    #expect(abs(result[2] - (-3.0)) < 1e-6)
}
