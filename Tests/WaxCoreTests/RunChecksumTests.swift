import Foundation
import Testing
@testable import WaxCore

// MARK: - Helpers

private let smallChunkBytes: UInt32 = RunChecksum.minimumChunkBytes

/// The tree checksum, one chunk after another: SHA-256 of the chunks' SHA-256 digests.
private func sequentialTreeChecksum(_ data: Data, chunkBytes: Int) -> Data {
    var digests = Data()
    var start = 0
    repeat {
        let end = min(start + chunkBytes, data.count)
        digests.append(SHA256Checksum.digest(data.subdata(in: start..<end)))
        start = end
    } while start < data.count
    return SHA256Checksum.digest(digests)
}

/// `count` bytes derived from their offset and `seed`. A pointer loop: a subscript loop is
/// slow in debug builds.
private func patternBytes(_ count: Int, seed: Int = 0) -> Data {
    let bytes = [UInt8](unsafeUninitializedCapacity: count) { buffer, initialized in
        var offset = 0
        while offset < count {
            buffer[offset] = UInt8(truncatingIfNeeded: offset &* 31 &+ (offset >> 12) &* 7 &+ seed &* 101)
            offset += 1
        }
        initialized = count
    }
    return Data(bytes)
}

private func fixtureVector(_ frame: Int, version: Int = 0) -> [Float] {
    (0..<8).map { Float(frame + 1) * 0.01 + Float($0) * 0.1 + Float(version) }
}

/// The lex image the `migration-v3-0-runs` fixture was written with: 4 KiB pages, page
/// `index` derived from `index` and `versions[index]`.
private func fixtureImage(pages: Int, versions: [Int: Int] = [:]) -> Data {
    var data = Data()
    for index in 0..<pages {
        let version = versions[index] ?? 0
        let page = [UInt8](unsafeUninitializedCapacity: 4096) { buffer, initialized in
            var offset = 0
            while offset < 4096 {
                buffer[offset] = UInt8(truncatingIfNeeded: index &* 31 &+ offset &* 7 &+ version &* 101)
                offset += 1
            }
            initialized = 4096
        }
        data.append(contentsOf: page)
    }
    return data
}

private func largeVector(_ frame: Int, dimension: Int) -> [Float] {
    (0..<dimension).map { Float(frame + 1) * 0.5 + Float($0) * 0.25 }
}

private func committedMap(_ wax: Wax) async throws -> [UInt64: [Float]] {
    guard let committed = try await wax.readCommittedVectors() else { return [:] }
    let dimension = Int(committed.dimension)
    var map: [UInt64: [Float]] = [:]
    for (row, frameId) in committed.frameIds.enumerated() {
        map[frameId] = Array(committed.vectors[(row * dimension)..<((row + 1) * dimension)])
    }
    return map
}

private func headerFormatVersions(_ url: URL) throws -> [UInt16] {
    let handle = try FileHandle(forReadingFrom: url)
    defer { try? handle.close() }
    let pages = try handle.read(upToCount: 8192) ?? Data()
    return [0, 4096].map { offset in
        UInt16(pages[offset + 4]) | (UInt16(pages[offset + 5]) << 8)
    }
}

private func flipByte(at offset: UInt64, of url: URL) throws {
    let file = try FDFile.open(at: url)
    defer { try? file.close() }
    var byte = try file.readExactly(length: 1, at: offset)
    byte[0] ^= 0xFF
    try file.writeAll(byte, at: offset)
    try file.fsync()
}

private func isChecksumMismatch(_ error: any Error) -> Bool {
    guard case WaxError.checksumMismatch = error else { return false }
    return true
}

// MARK: - Tree checksum

private let chunkBoundaryLengths: [Int] = [
    0, 1, 1000,
    Int(smallChunkBytes) - 1, Int(smallChunkBytes), Int(smallChunkBytes) + 1,
    5 * Int(smallChunkBytes) + 123, 8 * Int(smallChunkBytes),
]

@Test(arguments: chunkBoundaryLengths)
func treeChecksumMatchesASequentialReference(length: Int) {
    let data = patternBytes(length)
    let expected = sequentialTreeChecksum(data, chunkBytes: Int(smallChunkBytes))
    #expect(RunChecksum.digest(data, chunkBytes: smallChunkBytes) == expected)

    // Streamed in pieces that do not line up with the chunks.
    var hasher = RunChecksum.Hasher(chunkBytes: smallChunkBytes)
    var start = 0
    let piece = 10_007
    while start < data.count {
        let end = min(start + piece, data.count)
        data.subdata(in: start..<end).withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            hasher.update(raw)
        }
        start = end
    }
    #expect(hasher.finalize() == expected)
}

@Test func anEmptyOrSubChunkRunIsOneChunk() {
    let empty = Data()
    #expect(RunChecksum.digest(empty, chunkBytes: smallChunkBytes) == SHA256Checksum.digest(SHA256Checksum.digest(empty)))
    let small = patternBytes(777)
    #expect(RunChecksum.digest(small, chunkBytes: smallChunkBytes) == SHA256Checksum.digest(SHA256Checksum.digest(small)))
}

@Test func withoutAChunkSizeTheChecksumIsTheWholeRunSHA256() {
    let data = patternBytes(3 * Int(smallChunkBytes) + 5)
    #expect(RunChecksum.digest(data, chunkBytes: nil) == SHA256Checksum.digest(data))
    var hasher = RunChecksum.Hasher(chunkBytes: nil)
    data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in hasher.update(raw) }
    #expect(hasher.finalize() == SHA256Checksum.digest(data))
}

@Test func theTreeChecksumDependsOnTheChunkSize() {
    let data = patternBytes(5 * Int(smallChunkBytes))
    #expect(RunChecksum.digest(data, chunkBytes: smallChunkBytes) != RunChecksum.digest(data, chunkBytes: 2 * smallChunkBytes))
    #expect(RunChecksum.treeChunkBytes == 4 << 20)
}

@Test func aDefaultChunkSizeTreeChecksumOverManyChunksMatchesTheReference() {
    let data = patternBytes(3 * Int(RunChecksum.treeChunkBytes) + 99, seed: 3)
    let expected = sequentialTreeChecksum(data, chunkBytes: Int(RunChecksum.treeChunkBytes))
    #expect(RunChecksum.digest(data, chunkBytes: RunChecksum.treeChunkBytes) == expected)
}

// MARK: - Manifests

@Test func runManifestsRoundTripTheirChecksumChunkSize() throws {
    let lex = LexIndexManifest(
        docCount: 7,
        version: 1,
        pageSize: 4096,
        runs: [
            LexRunManifest(
                bytesOffset: 100, bytesLength: 8192, checksum: Data(repeating: 1, count: 32),
                addedGeneration: 3, imageLength: 8192, checksumChunkBytes: nil
            ),
            LexRunManifest(
                bytesOffset: 9000, bytesLength: 4124, checksum: Data(repeating: 2, count: 32),
                addedGeneration: 4, imageLength: 12_288, checksumChunkBytes: RunChecksum.treeChunkBytes
            ),
        ]
    )
    let vec = VecIndexManifest(
        vectorCount: 42,
        dimension: 384,
        similarity: .cosine,
        runs: [
            VecRunManifest(
                bytesOffset: 20_000, bytesLength: 4000, checksum: Data(repeating: 0xBB, count: 32),
                rowCount: 40, tombstoneCount: 0, level: 64, addedGeneration: 0,
                keysChecksum: nil, checksumChunkBytes: nil
            ),
            VecRunManifest(
                bytesOffset: 30_000, bytesLength: 100, checksum: Data(repeating: 0xCC, count: 32),
                rowCount: 2, tombstoneCount: 1, level: 0, addedGeneration: 9,
                keysChecksum: Data(repeating: 0xDD, count: 32), checksumChunkBytes: 1 << 20
            ),
        ]
    )
    var manifests = IndexManifests(lex: lex, vec: vec)
    var encoder = BinaryEncoder()
    try manifests.encode(to: &encoder)
    var decoder = try BinaryDecoder(data: encoder.data)
    #expect(try IndexManifests.decode(from: &decoder) == manifests)
    try decoder.finalize()
}

/// A 3.0 TOC: tag 2 for both manifests, and runs without a checksum chunk size.
@Test func aFormat30ManifestDecodesWithWholeRunChecksums() throws {
    var encoder = BinaryEncoder()
    encoder.encode(UInt8(2)) // lex runs
    encoder.encode(UInt64(7)) // doc count
    encoder.encode(UInt32(1)) // version
    encoder.encode(UInt32(4096)) // page size
    encoder.encode(UInt32(1)) // run count
    encoder.encode(UInt64(100))
    encoder.encode(UInt64(8192))
    encoder.encodeFixedBytes(Data(repeating: 1, count: 32))
    encoder.encode(UInt64(3))
    encoder.encode(UInt64(8192))
    encoder.encode(UInt8(2)) // vec runs
    encoder.encode(UInt64(2)) // vector count
    encoder.encode(UInt32(8)) // dimension
    encoder.encode(UInt8(0)) // similarity
    encoder.encode(UInt32(1)) // run count
    encoder.encode(UInt64(20_000))
    encoder.encode(UInt64(300))
    encoder.encodeFixedBytes(Data(repeating: 2, count: 32))
    encoder.encode(UInt64(2)) // rows
    encoder.encode(UInt64(0)) // tombstones
    encoder.encode(UInt8(0)) // level
    encoder.encode(UInt64(5)) // generation
    encoder.encode(UInt8(1)) // keys checksum present
    encoder.encodeFixedBytes(Data(repeating: 3, count: 32))
    encoder.encode(UInt8(0)) // clip absent

    var decoder = try BinaryDecoder(data: encoder.data)
    let decoded = try IndexManifests.decode(from: &decoder)
    try decoder.finalize()
    let lexRun = try #require(decoded.lex?.runs.first)
    #expect(lexRun.checksum == Data(repeating: 1, count: 32))
    #expect(lexRun.checksumChunkBytes == nil)
    let vecRun = try #require(decoded.vec?.runs.first)
    #expect(vecRun.keysChecksum == Data(repeating: 3, count: 32))
    #expect(vecRun.checksumChunkBytes == nil)
}

@Test func aChecksumChunkSizeBelowTheMinimumDoesNotDecode() throws {
    let run = LexRunManifest(
        bytesOffset: 100, bytesLength: 8192, checksum: Data(repeating: 1, count: 32),
        addedGeneration: 3, imageLength: 8192, checksumChunkBytes: RunChecksum.minimumChunkBytes - 1
    )
    var manifests = IndexManifests(lex: LexIndexManifest(docCount: 1, version: 1, pageSize: 4096, runs: [run]), vec: nil)
    var encoder = BinaryEncoder()
    #expect(throws: WaxError.self) {
        try manifests.encode(to: &encoder)
    }

    // Hand-encoded, since the encoder refuses it.
    var bytes = BinaryEncoder()
    bytes.encode(UInt8(3)) // lex runs with chunk sizes
    bytes.encode(UInt64(1))
    bytes.encode(UInt32(1))
    bytes.encode(UInt32(4096))
    bytes.encode(UInt32(1))
    bytes.encode(UInt64(100))
    bytes.encode(UInt64(8192))
    bytes.encodeFixedBytes(Data(repeating: 1, count: 32))
    bytes.encode(UInt64(3))
    bytes.encode(UInt64(8192))
    bytes.encode(UInt8(1)) // chunk size present
    bytes.encode(UInt32(0))
    bytes.encode(UInt8(0)) // vec absent
    bytes.encode(UInt8(0)) // clip absent
    var decoder = try BinaryDecoder(data: bytes.data)
    #expect(throws: WaxError.self) {
        _ = try IndexManifests.decode(from: &decoder)
    }
}

// MARK: - Vector run verify

private let checksumSchemes: [UInt32?] = [nil, RunChecksum.treeChunkBytes]

/// A run large enough to decode while it is hashed, under the whole-run SHA-256 of older
/// runs and the tree checksum of new ones; damage to its header is a checksum mismatch, not
/// a decode error.
@Test(arguments: checksumSchemes)
func aLargeVectorRunVerifiesUnderEitherChecksumScheme(chunkBytes: UInt32?) throws {
    let dimension = 384
    let rows = 2 * Int(RunChecksum.treeChunkBytes) / (dimension * 4) + 7
    var vectors: [Float] = []
    vectors.reserveCapacity(rows * dimension)
    for row in 0..<rows {
        vectors.append(contentsOf: largeVector(row, dimension: dimension))
    }
    let run = VecRun(
        dimension: UInt32(dimension),
        similarity: .dot,
        frameIds: (0..<rows).map(UInt64.init),
        vectors: vectors,
        tombstones: []
    )
    let bytes = try VecRunCodec.encode(run)
    #expect(bytes.count >= Wax.concurrentVecRunVerifyBytes)
    let checksum = RunChecksum.digest(bytes, chunkBytes: chunkBytes)
    #expect(try Wax.verifiedVecRun(bytes, checksum: checksum, checksumChunkBytes: chunkBytes) == run)

    for offset in [0, bytes.count / 2, bytes.count - 1] {
        var damaged = bytes
        damaged[offset] ^= 0xFF
        #expect {
            _ = try Wax.verifiedVecRun(damaged, checksum: checksum, checksumChunkBytes: chunkBytes)
        } throws: { error in
            isChecksumMismatch(error)
        }
    }
}

// MARK: - Format 3.0 stores

@Test func aFormat30StoreOpensAndItsFirstCommitWritesTreeChecksummedRuns() async throws {
    let url = try await copyMigrationFixture(named: "migration-v3-0-runs")
    defer { try? FileManager.default.removeItem(at: url) }
    #expect(try headerFormatVersions(url) == [0x0300, 0x0300])

    // Fixture: 41 frames; 8-dimension cosine vectors for frames 0...40, frame 5 re-embedded
    // once (two runs); a 12-page lex image with page 3 changed by the second commit (a base
    // and one delta).
    var expectedVectors = Dictionary(uniqueKeysWithValues: (0...40).map { (UInt64($0), fixtureVector($0)) })
    expectedVectors[5] = fixtureVector(5, version: 1)
    let committedImage = fixtureImage(pages: 12, versions: [3: 1])

    let wax = try await Wax.open(at: url)
    #expect(await wax.stats().frameCount == 41)
    #expect(try await committedMap(wax) == expectedVectors)
    #expect(try await wax.readCommittedLexIndexBytes() == committedImage)
    try await wax.verify(deep: true)
    let adoptedVec = try #require(await wax.committedVecIndexManifest())
    let adoptedLex = try #require(await wax.committedLexIndexManifest())
    #expect(adoptedVec.runs.count == 2)
    #expect(adoptedLex.runs.count == 2)
    #expect(adoptedVec.runs.allSatisfy { $0.checksumChunkBytes == nil })
    #expect(adoptedLex.runs.allSatisfy { $0.checksumChunkBytes == nil })
    // Opening and reading leave the file as 3.0 wrote it.
    #expect(try headerFormatVersions(url) == [0x0300, 0x0300])

    _ = try await wax.put(Data("v3.1-frame-41".utf8))
    try await wax.putEmbedding(frameId: 41, vector: fixtureVector(41))
    try await wax.putEmbedding(frameId: 7, vector: fixtureVector(7, version: 2))
    let nextImage = fixtureImage(pages: 12, versions: [3: 1, 7: 2])
    try await wax.stageLexIndexForNextCommit(bytes: nextImage, docCount: 42)
    try await wax.commit()
    expectedVectors[41] = fixtureVector(41)
    expectedVectors[7] = fixtureVector(7, version: 2)

    let vec = try #require(await wax.committedVecIndexManifest())
    #expect(vec.runs.count == 3)
    #expect(Array(vec.runs.prefix(2)) == adoptedVec.runs, "the 3.0 runs stay as they were, with whole-run checksums")
    #expect(vec.runs[2].checksumChunkBytes == RunChecksum.treeChunkBytes)
    let lex = try #require(await wax.committedLexIndexManifest())
    #expect(lex.runs.count == 3)
    #expect(Array(lex.runs.prefix(2)) == adoptedLex.runs)
    #expect(lex.runs[2].checksumChunkBytes == RunChecksum.treeChunkBytes)
    #expect(try await committedMap(wax) == expectedVectors)
    #expect(try await wax.readCommittedLexIndexBytes() == nextImage)
    try await wax.verify(deep: true)
    try await wax.close()
    // Both header pages are current now, so a 3.0 build refuses the file.
    #expect(Constants.specVersion == 0x0301)
    #expect(try headerFormatVersions(url) == [0x0301, 0x0301])

    let reopened = try await Wax.open(at: url)
    #expect(try await committedMap(reopened) == expectedVectors)
    #expect(try await reopened.readCommittedLexIndexBytes() == nextImage)
    try await reopened.verify(deep: true)
    try await reopened.close()
}

@Test func aFormat30BuildRefusesAFormat31Header() throws {
    #expect(!Constants.supportedSpecVersions.subtracting([Constants.specVersion]).contains(0x0301))
    #expect(Constants.supportedSpecVersions.isSuperset(of: [0x0100, 0x0200, 0x0300, 0x0301]))
}

// MARK: - Damage

enum TreeRunDamage: String, CaseIterable, Sendable {
    case header
    case lastByteOfFirstChunk
    case firstByteOfSecondChunk
    case middleChunk
    case lastPartialChunk

    func offset(in run: (offset: UInt64, length: UInt64)) -> UInt64 {
        let chunk = UInt64(RunChecksum.treeChunkBytes)
        switch self {
        case .header: return run.offset
        case .lastByteOfFirstChunk: return run.offset + chunk - 1
        case .firstByteOfSecondChunk: return run.offset + chunk
        case .middleChunk: return run.offset + chunk + chunk / 2
        case .lastPartialChunk: return run.offset + run.length - 1
        }
    }
}

private let vectorRunDamages: [TreeRunDamage] = TreeRunDamage.allCases
private let lexRunDamages: [TreeRunDamage] = [.lastByteOfFirstChunk, .firstByteOfSecondChunk, .middleChunk, .lastPartialChunk]

/// The runs of the `migration-v3-0-runs` fixture, written by format 3.0.
enum LegacyRunKind: String, CaseIterable, Sendable {
    case vector
    case lex
}

private let legacyRunKinds: [LegacyRunKind] = LegacyRunKind.allCases

/// Runs a format 3.0 store wrote keep their whole-run SHA-256: damage in the middle of one
/// fails the read and the deep verify.
@Test(arguments: legacyRunKinds)
func damageToAWholeRunChecksummedRunFailsTheRead(kind: LegacyRunKind) async throws {
    let url = try await copyMigrationFixture(named: "migration-v3-0-runs")
    defer { try? FileManager.default.removeItem(at: url) }
    let wax = try await Wax.open(at: url)
    let run: (offset: UInt64, length: UInt64, chunkBytes: UInt32?)
    switch kind {
    case .vector:
        let first = try #require(await wax.committedVecIndexManifest()?.runs.first)
        run = (first.bytesOffset, first.bytesLength, first.checksumChunkBytes)
    case .lex:
        let first = try #require(await wax.committedLexIndexManifest()?.runs.first)
        run = (first.bytesOffset, first.bytesLength, first.checksumChunkBytes)
    }
    try await wax.close()
    #expect(run.chunkBytes == nil)

    try flipByte(at: run.offset + run.length / 2, of: url)

    let reopened = try await Wax.open(at: url)
    await #expect {
        switch kind {
        case .vector: _ = try await reopened.readCommittedVectors()
        case .lex: _ = try await reopened.readCommittedLexIndexBytes()
        }
    } throws: { (error: any Error) -> Bool in
        isChecksumMismatch(error)
    }
    await #expect {
        try await reopened.verify(deep: true)
    } throws: { (error: any Error) -> Bool in
        isChecksumMismatch(error)
    }
    try await reopened.close()
}

/// A tree-checksummed run of three chunks, the last partial: damage anywhere fails the read
/// with a checksum mismatch, before any decode error.
@Test(arguments: vectorRunDamages)
func damageToATreeChecksummedVectorRunFailsTheRead(damage: TreeRunDamage) async throws {
    try await TempFiles.withTempFile { url in
        let dimension = 384
        let chunk = Int(RunChecksum.treeChunkBytes)
        let count = (2 * chunk + chunk / 2) / (dimension * 4)
        // The embeddings are logged before the commit writes them as one run.
        let wax = try await Wax.create(at: url, walSize: 32 << 20)
        for index in 0..<count {
            _ = try await wax.put(Data("frame \(index)".utf8))
        }
        try await wax.setVectorIndexConfiguration(dimension: UInt32(dimension), similarity: .dot)
        let ids = (0..<count).map(UInt64.init)
        try await wax.putEmbeddingBatch(frameIds: ids, vectors: ids.map { largeVector(Int($0), dimension: dimension) })
        try await wax.commit()
        let run = try #require(await wax.committedVecIndexManifest()?.runs.first)
        #expect(run.checksumChunkBytes == RunChecksum.treeChunkBytes)
        #expect(run.bytesLength > 2 * UInt64(chunk) && run.bytesLength % UInt64(chunk) != 0)
        #expect(run.checksum == RunChecksum.digest(
            try FDFile.open(at: url).readExactly(length: Int(run.bytesLength), at: run.bytesOffset),
            chunkBytes: RunChecksum.treeChunkBytes
        ))
        try await wax.close()

        let intact = try await Wax.open(at: url)
        #expect(try await committedMap(intact)[UInt64(count - 1)] == largeVector(count - 1, dimension: dimension))
        try await intact.verify(deep: true)
        try await intact.close()

        try flipByte(at: damage.offset(in: (run.bytesOffset, run.bytesLength)), of: url)

        let reopened = try await Wax.open(at: url)
        await #expect {
            _ = try await reopened.readCommittedVectors()
        } throws: { error in
            isChecksumMismatch(error)
        }
        await #expect {
            try await reopened.verify(deep: true)
        } throws: { error in
            isChecksumMismatch(error)
        }
        try await reopened.close()
    }
}

@Test(arguments: lexRunDamages)
func damageToATreeChecksummedLexRunFailsTheRead(damage: TreeRunDamage) async throws {
    try await TempFiles.withTempFile { url in
        let chunk = Int(RunChecksum.treeChunkBytes)
        let image = patternBytes(2 * chunk + chunk / 2 + 4096, seed: 11)
        let wax = try await Wax.create(at: url)
        try await wax.stageLexIndexForNextCommit(bytes: image, docCount: 1)
        try await wax.commit()
        let run = try #require(await wax.committedLexIndexManifest()?.runs.first)
        #expect(run.checksumChunkBytes == RunChecksum.treeChunkBytes)
        #expect(run.checksum == RunChecksum.digest(image, chunkBytes: RunChecksum.treeChunkBytes))
        try await wax.close()

        let intact = try await Wax.open(at: url)
        #expect(try await intact.readCommittedLexIndexBytes() == image)
        try await intact.verify(deep: true)
        try await intact.close()

        try flipByte(at: damage.offset(in: (run.bytesOffset, run.bytesLength)), of: url)

        let reopened = try await Wax.open(at: url)
        await #expect {
            _ = try await reopened.readCommittedLexIndexBytes()
        } throws: { error in
            isChecksumMismatch(error)
        }
        await #expect {
            try await reopened.verify(deep: true)
        } throws: { error in
            isChecksumMismatch(error)
        }
        try await reopened.close()
    }
}
