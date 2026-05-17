import Foundation
import Testing
import GRDB
import Logging
@testable import WaxVectorSearch

@Test func packageManifestDoesNotDependOnRemovedVectorDependency() throws {
    let repoRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
    let manifest = try String(
        contentsOf: repoRoot.appendingPathComponent("Package.swift"),
        encoding: .utf8
    )

    let removedPackageName = "U" + "Search"
    let removedPackageIdentity = "u" + "search"

    #expect(!manifest.contains(removedPackageName))
    #expect(!manifest.contains(removedPackageIdentity))
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
