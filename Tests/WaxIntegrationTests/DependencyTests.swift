import Testing
import USearch
import GRDB
import Logging
@testable import WaxVectorSearch

@Test func usearchInitializes() throws {
    let index = try USearchIndex.make(
        metric: .cos,
        dimensions: 128,
        connectivity: 16,
        quantization: .f32
    )
    #expect(String(describing: index).contains("USearchIndex"))
}

#if canImport(Metal) && canImport(MetalANNS)
@Test func metalANNSVectorEngineInitializes() throws {
    _ = try MetalANNSVectorEngine(metric: .cosine, dimensions: 128)
}
#endif

@Test func grdbInitializes() throws {
    let dbQueue = try DatabaseQueue()
    try dbQueue.write { db in
        try db.execute(sql: "CREATE TABLE test (id INTEGER PRIMARY KEY)")
    }
}

@Test func swiftLogInitializes() {
    let logger = Logger(label: "com.wax.swift.test")
    logger.info("swift-log initialized")
}
