import Foundation
import Testing
import Wax

@Test func structuredMemoryPersistsAcrossReopen() async throws {
    let tempDir = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)

    let fileURL = tempDir.appendingPathComponent("sample.wax")
    let wax = try await Wax.create(at: fileURL)

    let session = try await wax.structuredMemory()
    _ = try await session.upsertEntity(
        key: EntityKey("person:alice"),
        kind: "person",
        aliases: ["Alice"],
        nowMs: 10
    )
    _ = try await session.assertFact(
        subject: EntityKey("person:alice"),
        predicate: PredicateKey("status"),
        object: .string("active"),
        valid: StructuredTimeRange(fromMs: 0, toMs: nil),
        system: StructuredTimeRange(fromMs: 10, toMs: nil),
        evidence: []
    )
    try await session.commit()
    try await wax.close()

    let reopened = try await Wax.open(at: fileURL)
    let session2 = try await reopened.structuredMemory()
    let result = try await session2.facts(
        about: EntityKey("person:alice"),
        predicate: PredicateKey("status"),
        asOf: .latest,
        limit: 10
    )
    #expect(result.hits.count == 1)
    try await reopened.close()

    let files = try FileManager.default.contentsOfDirectory(atPath: tempDir.path)
    let baseName = fileURL.lastPathComponent
    let forbidden = [
        "\(baseName)-wal",
        "\(baseName)-shm",
        "\(baseName)-journal",
        "\(baseName).db",
        "\(baseName).sqlite",
        "\(baseName).sqlite3",
    ]
    for name in forbidden {
        #expect(!files.contains(name))
    }

    try FileManager.default.removeItem(at: tempDir)
}
