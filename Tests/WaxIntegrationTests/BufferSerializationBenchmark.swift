#if canImport(XCTest)
import XCTest
import Foundation
@testable import WaxVectorSearch
@testable import Wax
import USearch

/// Micro-benchmark comparing file-based vs buffer-based vector serialization.
/// This tests the primary bottleneck fix (Fix #1).
final class BufferSerializationBenchmark: XCTestCase {
    
    // Test configuration
    private let vectorCount = 1000
    private let dimensions = 384  // MiniLM dimensions
    private let iterations = 5
    
    func testBufferSerializationVsFileBased() async throws {
        // Create and populate an index
        let index = try USearchIndex.make(
            metric: .cos,
            dimensions: UInt32(dimensions),
            connectivity: 16,
            quantization: .f32
        )
        try index.reserve(UInt32(vectorCount))
        
        // Add random vectors
        for i in 0..<vectorCount {
            var vector = [Float](repeating: 0, count: dimensions)
            for j in 0..<dimensions {
                vector[j] = Float.random(in: -1...1)
            }
            try index.add(key: UInt64(i), vector: vector)
        }
        
        print("\n🧪 Buffer Serialization Benchmark")
        print("   Vectors: \(vectorCount), Dimensions: \(dimensions)")
        print("   Iterations: \(iterations)\n")
        
        // Benchmark buffer-based serialization (new)
        var bufferSaveTimes: [Double] = []
        var bufferLoadTimes: [Double] = []
        
        for i in 0..<iterations {
            // Save
            let saveStart = CFAbsoluteTimeGetCurrent()
            let data = try index.serializeToData()
            let saveEnd = CFAbsoluteTimeGetCurrent()
            bufferSaveTimes.append(saveEnd - saveStart)
            
            // Load into new index
            let loadIndex = try USearchIndex.make(
                metric: .cos,
                dimensions: UInt32(dimensions),
                connectivity: 16,
                quantization: .f32
            )
            let loadStart = CFAbsoluteTimeGetCurrent()
            try loadIndex.deserializeFromData(data)
            let loadEnd = CFAbsoluteTimeGetCurrent()
            bufferLoadTimes.append(loadEnd - loadStart)
            
            if i == 0 {
                print("   Serialized size: \(data.count) bytes (\(data.count / 1024) KB)")
            }
        }
        
        // Benchmark file-based serialization (old)
        var fileSaveTimes: [Double] = []
        var fileLoadTimes: [Double] = []
        
        for _ in 0..<iterations {
            let tempURL = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString)
                .appendingPathExtension("usearch")
            defer { try? FileManager.default.removeItem(at: tempURL) }
            
            // Save to file
            let saveStart = CFAbsoluteTimeGetCurrent()
            try index.save(path: tempURL.path)
            let saveEnd = CFAbsoluteTimeGetCurrent()
            fileSaveTimes.append(saveEnd - saveStart)
            
            // Load from file
            let loadIndex = try USearchIndex.make(
                metric: .cos,
                dimensions: UInt32(dimensions),
                connectivity: 16,
                quantization: .f32
            )
            let loadStart = CFAbsoluteTimeGetCurrent()
            try loadIndex.load(path: tempURL.path)
            let loadEnd = CFAbsoluteTimeGetCurrent()
            fileLoadTimes.append(loadEnd - loadStart)
        }
        
        // Calculate statistics
        let bufferSaveAvg = bufferSaveTimes.reduce(0, +) / Double(iterations)
        let bufferLoadAvg = bufferLoadTimes.reduce(0, +) / Double(iterations)
        let fileSaveAvg = fileSaveTimes.reduce(0, +) / Double(iterations)
        let fileLoadAvg = fileLoadTimes.reduce(0, +) / Double(iterations)
        
        let saveSpeedup = fileSaveAvg / bufferSaveAvg
        let loadSpeedup = fileLoadAvg / bufferLoadAvg
        let totalSpeedup = (fileSaveAvg + fileLoadAvg) / (bufferSaveAvg + bufferLoadAvg)
        
        print("   📊 Results:")
        print("   ─────────────────────────────────────")
        print("   SAVE (buffer): \(String(format: "%.4f", bufferSaveAvg * 1000)) ms avg")
        print("   SAVE (file):   \(String(format: "%.4f", fileSaveAvg * 1000)) ms avg")
        print("   SAVE speedup:  \(String(format: "%.1f", saveSpeedup))x faster")
        print("")
        print("   LOAD (buffer): \(String(format: "%.4f", bufferLoadAvg * 1000)) ms avg")
        print("   LOAD (file):   \(String(format: "%.4f", fileLoadAvg * 1000)) ms avg")
        print("   LOAD speedup:  \(String(format: "%.1f", loadSpeedup))x faster")
        print("")
        print("   ✅ TOTAL speedup: \(String(format: "%.1f", totalSpeedup))x faster")
        print("   ─────────────────────────────────────\n")
        
        // Assert improvement
        XCTAssertGreaterThan(saveSpeedup, 1.0, "Buffer save should be faster than file save")
        XCTAssertGreaterThan(loadSpeedup, 1.0, "Buffer load should be faster than file load")
    }
}
#endif
