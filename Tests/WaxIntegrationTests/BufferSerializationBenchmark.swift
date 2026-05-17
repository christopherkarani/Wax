#if canImport(XCTest)
import Foundation
import XCTest
@testable import WaxVectorSearch

final class BufferSerializationBenchmark: XCTestCase {
    private let vectorCount = 1_000
    private let dimensions = 384
    private let iterations = 5

    func testFlatVectorSerializationRoundTripBenchmark() throws {
        let frameIds = (0..<vectorCount).map(UInt64.init)
        let vectors = makeFlatVectors(count: vectorCount, dimensions: dimensions)

        print("\nFlat Vector Serialization Benchmark")
        print("   Vectors: \(vectorCount), Dimensions: \(dimensions)")
        print("   Iterations: \(iterations)\n")

        var encodeTimes: [Double] = []
        var decodeTimes: [Double] = []
        var serializedSize = 0

        for _ in 0..<iterations {
            let encodeStart = CFAbsoluteTimeGetCurrent()
            let data = try VectorSerializer.serializeFlatVectors(
                vectors,
                frameIds: frameIds,
                metric: .cosine,
                dimensions: dimensions
            )
            let encodeEnd = CFAbsoluteTimeGetCurrent()
            encodeTimes.append(encodeEnd - encodeStart)
            serializedSize = data.count

            let decodeStart = CFAbsoluteTimeGetCurrent()
            let decoded = try VectorSerializer.decodeVecSegment(from: data)
            let decodeEnd = CFAbsoluteTimeGetCurrent()
            decodeTimes.append(decodeEnd - decodeStart)

            guard case .metal(let info, let decodedVectors, let decodedFrameIds) = decoded else {
                XCTFail("Expected flat vector payload to decode as metal-compatible vectors")
                return
            }
            XCTAssertEqual(info.vectorCount, UInt64(vectorCount))
            XCTAssertEqual(decodedVectors.count, vectors.count)
            XCTAssertEqual(decodedFrameIds, frameIds)
        }

        let encodeAverage = encodeTimes.reduce(0, +) / Double(iterations)
        let decodeAverage = decodeTimes.reduce(0, +) / Double(iterations)

        print("   Serialized size: \(serializedSize) bytes (\(serializedSize / 1024) KB)")
        print("   Encode avg: \(String(format: "%.4f", encodeAverage * 1000)) ms")
        print("   Decode avg: \(String(format: "%.4f", decodeAverage * 1000)) ms\n")
    }

    private func makeFlatVectors(count: Int, dimensions: Int) -> [Float] {
        var vectors: [Float] = []
        vectors.reserveCapacity(count * dimensions)
        for index in 0..<count {
            for dim in 0..<dimensions {
                vectors.append(Float((index + dim) % 256) / 255.0)
            }
        }
        return vectors
    }
}
#endif
