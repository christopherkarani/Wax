import Foundation
import Testing
@testable import WaxCore

// MARK: - StructuredMemoryValidation (malformed / boundary / invalid assumptions)

@Test(
    "validateEntityKey rejects empty and whitespace-only keys",
    arguments: ["", "   ", "\t\n", "\u{00A0}"]
)
func validateEntityKeyRejectsBlank(_ raw: String) {
    #expect(throws: WaxError.self) {
        try StructuredMemoryValidation.validateEntityKey(EntityKey(raw))
    }
}

@Test func validateEntityKeyAcceptsNonEmpty() throws {
    try StructuredMemoryValidation.validateEntityKey(EntityKey("alice"))
    try StructuredMemoryValidation.validateEntityKey(EntityKey("  alice  "))
}

@Test func validateEntityKeyRejectsOverCapacityUTF8() {
    // maxKeyUTF8Bytes = 4096; multi-byte code units must count toward the limit.
    let tooLong = String(repeating: "é", count: StructuredMemoryValidation.maxKeyUTF8Bytes)
    #expect(tooLong.utf8.count > StructuredMemoryValidation.maxKeyUTF8Bytes)
    #expect(throws: WaxError.self) {
        try StructuredMemoryValidation.validateEntityKey(EntityKey(tooLong))
    }
}

@Test func validateEntityKeyAcceptsExactlyMaxUTF8Bytes() throws {
    let exact = String(repeating: "a", count: StructuredMemoryValidation.maxKeyUTF8Bytes)
    #expect(exact.utf8.count == StructuredMemoryValidation.maxKeyUTF8Bytes)
    try StructuredMemoryValidation.validateEntityKey(EntityKey(exact))
}

@Test func validatePredicateKeyRejectsEmpty() {
    #expect(throws: WaxError.self) {
        try StructuredMemoryValidation.validatePredicateKey(PredicateKey(""))
    }
}

@Test func validateFactValueEntityDelegatesToEntityKeyValidation() {
    #expect(throws: WaxError.self) {
        try StructuredMemoryValidation.validateFactValue(.entity(EntityKey("   ")))
    }
}

@Test func validateFactValueNonEntityPasses() throws {
    try StructuredMemoryValidation.validateFactValue(.string("ok"))
    try StructuredMemoryValidation.validateFactValue(.int(0))
    try StructuredMemoryValidation.validateFactValue(.bool(false))
    try StructuredMemoryValidation.validateFactValue(.data(Data()))
    try StructuredMemoryValidation.validateFactValue(.timeMs(-1))
}

@Test func validateEvidenceRejectsNegativeSpanStart() {
    let evidence = [
        StructuredEvidence(
            sourceFrameId: 1,
            spanUTF8: (-1)..<5,
            extractorId: "x",
            extractorVersion: "1",
            assertedAtMs: 0
        ),
    ]
    #expect(throws: WaxError.self) {
        try StructuredMemoryValidation.validateEvidence(evidence)
    }
}

@Test func validateEvidenceRejectsEmptySpan() {
    let evidence = [
        StructuredEvidence(
            sourceFrameId: 1,
            spanUTF8: 3..<3,
            extractorId: "x",
            extractorVersion: "1",
            assertedAtMs: 0
        ),
    ]
    #expect(throws: WaxError.self) {
        try StructuredMemoryValidation.validateEvidence(evidence)
    }
}

@Test(
    "validateEvidence rejects non-finite or out-of-range confidence",
    arguments: [
        Double.nan,
        Double.infinity,
        -Double.infinity,
        -0.0001,
        1.0001,
    ]
)
func validateEvidenceRejectsBadConfidence(_ confidence: Double) {
    let evidence = [
        StructuredEvidence(
            sourceFrameId: 1,
            extractorId: "x",
            extractorVersion: "1",
            confidence: confidence,
            assertedAtMs: 0
        ),
    ]
    #expect(throws: WaxError.self) {
        try StructuredMemoryValidation.validateEvidence(evidence)
    }
}

@Test func validateEvidenceAcceptsBoundaryConfidenceAndNil() throws {
    let evidence = [
        StructuredEvidence(
            sourceFrameId: 1,
            spanUTF8: 0..<1,
            extractorId: "x",
            extractorVersion: "1",
            confidence: 0,
            assertedAtMs: 0
        ),
        StructuredEvidence(
            sourceFrameId: 2,
            extractorId: "y",
            extractorVersion: "1",
            confidence: 1,
            assertedAtMs: 1
        ),
        StructuredEvidence(
            sourceFrameId: 3,
            extractorId: "z",
            extractorVersion: "1",
            confidence: nil,
            assertedAtMs: 2
        ),
    ]
    try StructuredMemoryValidation.validateEvidence(evidence)
    try StructuredMemoryValidation.validateEvidence([])
}

@Test func hashFactRejectsEmptySubjectAsRegression() {
    // Validation is on the hashFact path used by structured memory writers.
    #expect(throws: WaxError.self) {
        _ = try StructuredMemoryHasher.hashFact(
            subject: EntityKey(""),
            predicate: PredicateKey("knows"),
            object: .string("bob"),
            qualifiersHash: nil
        )
    }
}

@Test func hashFactRejectsWrongQualifierHashLength() {
    #expect(throws: WaxError.self) {
        _ = try StructuredMemoryHasher.hashFact(
            subject: EntityKey("a"),
            predicate: PredicateKey("p"),
            object: .int(1),
            qualifiersHash: Data(repeating: 0xAB, count: 16)
        )
    }
}

// MARK: - StructuredMemoryCanonicalizer

@Test func canonicalizerFoldsCaseAndDiacritics() {
    let a = StructuredMemoryCanonicalizer.normalizedString("Café")
    let b = StructuredMemoryCanonicalizer.normalizedString("CAFE")
    #expect(a == b)
}

@Test func canonicalizerAliasCollapsesInternalWhitespace() {
    let alias = StructuredMemoryCanonicalizer.normalizedAlias("  Alice   Bob\t\nCarol  ")
    #expect(alias == "alice bob carol")
}

@Test func canonicalizerAliasEmptyAfterTrimIsEmpty() {
    #expect(StructuredMemoryCanonicalizer.normalizedAlias("   \n\t  ") == "")
}

// MARK: - BinaryCodec adversarial / resource bounds

@Test func binaryDecoderEmptyBufferThrowsOnPrimitive() throws {
    var decoder = try BinaryDecoder(data: Data())
    #expect(throws: WaxError.self) {
        _ = try decoder.decode(UInt8.self)
    }
}

@Test func binaryDecoderInvalidOptionalTagThrows() throws {
    var decoder = try BinaryDecoder(data: Data([0x02, 0x00]))
    #expect(throws: WaxError.self) {
        _ = try decoder.decodeOptional(UInt8.self)
    }
}

@Test func binaryDecoderRejectsClaimedLengthOverTightLimit() throws {
    var limits = BinaryDecoder.Limits()
    limits.maxBlobBytes = 4
    // length = 5, then 5 payload bytes
    var bytes = Data()
    var lenLE = UInt32(5).littleEndian
    withUnsafeBytes(of: &lenLE) { bytes.append(contentsOf: $0) }
    bytes.append(Data(repeating: 0xAA, count: 5))

    var decoder = try BinaryDecoder(data: bytes, limits: limits)
    #expect(throws: WaxError.self) {
        _ = try decoder.decodeBytes()
    }
}

@Test func binaryDecoderRejectsArrayCountOverTightLimit() throws {
    var limits = BinaryDecoder.Limits()
    limits.maxArrayCount = 2
    var bytes = Data()
    var countLE = UInt32(3).littleEndian
    withUnsafeBytes(of: &countLE) { bytes.append(contentsOf: $0) }
    bytes.append(contentsOf: [1, 2, 3])

    var decoder = try BinaryDecoder(data: bytes, limits: limits)
    #expect(throws: WaxError.self) {
        let _: [UInt8] = try decoder.decodeArray()
    }
}

@Test func binaryDecoderRejectsStringLengthOverTightLimit() throws {
    var limits = BinaryDecoder.Limits()
    limits.maxStringBytes = 3
    var encoder = BinaryEncoder()
    try encoder.encode("abcd") // 4 UTF-8 bytes
    var decoder = try BinaryDecoder(data: encoder.data, limits: limits)
    #expect(throws: WaxError.self) {
        _ = try decoder.decode(String.self)
    }
}

@Test func binaryDecoderLengthClaimWithTruncatedPayloadThrows() throws {
    // Claims 100 bytes but only provides 2.
    var bytes = Data()
    var lenLE = UInt32(100).littleEndian
    withUnsafeBytes(of: &lenLE) { bytes.append(contentsOf: $0) }
    bytes.append(contentsOf: [0x01, 0x02])
    var decoder = try BinaryDecoder(data: bytes)
    #expect(throws: WaxError.self) {
        _ = try decoder.decodeBytes()
    }
}

@Test func binaryEncoderRejectsStringOverTightLimit() {
    var limits = BinaryEncoder.Limits()
    limits.maxStringBytes = 2
    var encoder = BinaryEncoder(limits: limits)
    #expect(throws: WaxError.self) {
        try encoder.encode("abc")
    }
}

@Test func binaryEncoderRejectsBlobOverTightLimit() {
    var limits = BinaryEncoder.Limits()
    limits.maxBlobBytes = 3
    var encoder = BinaryEncoder(limits: limits)
    #expect(throws: WaxError.self) {
        try encoder.encodeBytes(Data(repeating: 1, count: 4))
    }
}

@Test func binaryEncoderRejectsArrayCountOverTightLimit() {
    var limits = BinaryEncoder.Limits()
    limits.maxArrayCount = 2
    var encoder = BinaryEncoder(limits: limits)
    #expect(throws: WaxError.self) {
        try encoder.encode([UInt8(1), UInt8(2), UInt8(3)])
    }
}

@Test func binaryEncoderAcceptsAtExactLimit() throws {
    var limits = BinaryEncoder.Limits()
    limits.maxArrayCount = 2
    limits.maxBlobBytes = 2
    limits.maxStringBytes = 2
    var encoder = BinaryEncoder(limits: limits)
    try encoder.encode([UInt8(9), UInt8(8)])
    try encoder.encodeBytes(Data([0xAA, 0xBB]))
    try encoder.encode("ab")
    #expect(!encoder.data.isEmpty)
}

@Test func binaryDecoderUnsupportedTypeThrows() throws {
    var decoder = try BinaryDecoder(data: Data([0x00]))
    #expect(throws: WaxError.self) {
        _ = try decoder.decode(Float.self)
    }
}

// MARK: - WALEntryCodec malformed / invalid assumptions

@Test func walEntryCodecUnknownOpcodeThrowsCorruption() {
    #expect(throws: WaxError.self) {
        _ = try WALEntryCodec.decode(Data([0xFF]), offset: 99)
    }
}

@Test func walEntryCodecTruncatedDeleteThrowsCorruption() {
    // opcode deleteFrame but missing frameId
    #expect(throws: WaxError.self) {
        _ = try WALEntryCodec.decode(Data([0x02]), offset: 7)
    }
}

@Test func walEntryCodecDeleteWithTrailingBytesThrows() {
    var payload = Data([0x02])
    var frameLE = UInt64(1).littleEndian
    withUnsafeBytes(of: &frameLE) { payload.append(contentsOf: $0) }
    payload.append(0xDE) // excess
    #expect(throws: WaxError.self) {
        _ = try WALEntryCodec.decode(payload, offset: 0)
    }
}

@Test func walEntryCodecDeleteRoundtripBoundaryIds() throws {
    for id: UInt64 in [0, 1, UInt64.max] {
        let encoded = try WALEntryCodec.encode(.deleteFrame(DeleteFrame(frameId: id)))
        let decoded = try WALEntryCodec.decode(encoded, offset: 0)
        #expect(decoded == .deleteFrame(DeleteFrame(frameId: id)))
    }
}

@Test func walEntryCodecPutEmbeddingDimensionMismatchThrows() {
    let bad = PutEmbedding(frameId: 1, dimension: 3, vector: [1.0, 2.0]) // dim != count
    #expect(throws: WaxError.self) {
        _ = try WALEntryCodec.encode(.putEmbedding(bad))
    }
}

@Test func walEntryCodecPutFrameRejectsShortChecksums() throws {
    let options = FrameMetaSubset()
    let put = PutFrame(
        frameId: 1,
        timestampMs: 0,
        options: options,
        payloadOffset: 0,
        payloadLength: 0,
        canonicalEncoding: .plain,
        canonicalLength: 0,
        canonicalChecksum: Data(repeating: 0, count: 16), // wrong size
        storedChecksum: Data(repeating: 0, count: 32)
    )
    #expect(throws: WaxError.self) {
        _ = try WALEntryCodec.encode(.putFrame(put))
    }
}

@Test func walEntryCodecEmptyPayloadThrows() {
    #expect(throws: WaxError.self) {
        _ = try WALEntryCodec.decode(Data(), offset: 0)
    }
}

// MARK: - PayloadCompressor adversarial / exhaustion-safe

@Test func payloadCompressorEmptyCompressReturnsEmpty() throws {
    let out = try PayloadCompressor.compress(Data(), algorithm: .lz4)
    #expect(out.isEmpty)
}

@Test func payloadCompressorNoneIgnoresUncompressedLengthClaim() throws {
    let original = Data([1, 2, 3])
    let out = try PayloadCompressor.decompress(original, algorithm: .none, uncompressedLength: 999)
    #expect(out == original)
}

@Test func payloadCompressorRejectsNegativeUncompressedLength() {
    #expect(throws: WaxError.self) {
        _ = try PayloadCompressor.decompress(Data([1]), algorithm: .lz4, uncompressedLength: -1)
    }
}

@Test func payloadCompressorZeroUncompressedLengthReturnsEmpty() throws {
    let out = try PayloadCompressor.decompress(Data([0xFF, 0x00]), algorithm: .lz4, uncompressedLength: 0)
    #expect(out.isEmpty)
}

@Test func payloadCompressorGarbageBytesWithWrongLengthThrows() {
    let garbage = Data([0x00, 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07])
    #expect(throws: WaxError.self) {
        _ = try PayloadCompressor.decompress(garbage, algorithm: .lz4, uncompressedLength: 64)
    }
}

// MARK: - ContentHasher / checksum boundary

@Test func contentHasherEmptyDataIsStable() {
    let a = ContentHasher.hash(Data())
    let b = ContentHasher.hash(Data())
    #expect(a == b)
    #expect(a.count == 32)
}

@Test func sha256EmptyDigestMatchesKnownValue() {
    // SHA-256("") well-known digest
    let digest = SHA256Checksum.digest(Data())
    #expect(digest.hexString == "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
}

// MARK: - WALRecord header corruption / boundaries

@Test func walRecordHeaderRejectsWrongChecksumSizeOnEncode() {
    let header = WALRecordHeader(
        sequence: 1,
        length: 0,
        flags: [],
        checksum: Data(repeating: 0, count: 8)
    )
    #expect(throws: WaxError.self) {
        _ = try header.encode()
    }
}

@Test func walRecordHeaderRejectsWrongDecodeSize() {
    #expect(throws: WaxError.self) {
        _ = try WALRecordHeader.decode(from: Data(repeating: 0, count: 10), offset: 0)
    }
}

@Test func walRecordHeaderSentinelRoundtrip() throws {
    let header = WALRecordHeader(
        sequence: 0,
        length: 0,
        flags: [],
        checksum: Data(repeating: 0, count: WALRecord.checksumSize)
    )
    #expect(header.isSentinel)
    let encoded = try header.encode()
    #expect(encoded.count == WALRecordHeader.size)
    let decoded = try WALRecordHeader.decode(from: encoded, offset: 0)
    #expect(decoded.isSentinel)
}

// MARK: - VersionRelation invalid assumptions

@Test func versionRelationSupersedesOnlyUpdatesAndRetracts() {
    #expect(VersionRelation.sets.supersedes == false)
    #expect(VersionRelation.extends.supersedes == false)
    #expect(VersionRelation.updates.supersedes == true)
    #expect(VersionRelation.retracts.supersedes == true)
    #expect(VersionRelation(rawValue: 99) == nil)
}

// MARK: - AsyncTimeout adversarial / boundary

@Test func asyncTimeoutReturnsWhenOperationCompletesFirst() async throws {
    let value = try await AsyncTimeout.run(
        timeout: .seconds(5),
        operation: "adversarial-fast-success"
    ) {
        42
    }
    #expect(value == 42)
}

@Test func asyncTimeoutFiresWhenOperationHangs() async {
    await #expect(throws: AsyncTimeout.TimeoutError.self) {
        _ = try await AsyncTimeout.run(
            timeout: .milliseconds(20),
            operation: "adversarial-hang"
        ) {
            try await Task.sleep(for: .seconds(30))
            return 0
        }
    }
}

// MARK: - Concurrency: bounded multi-writer no lost updates

@Test func asyncMutexNoLostUpdatesUnderContention() async throws {
    let mutex = AsyncMutex()
    let iterations = 200
    let workers = 8
    let counter = AdversarialCounter()

    try await withThrowingTaskGroup(of: Void.self) { group in
        for _ in 0..<workers {
            group.addTask {
                for _ in 0..<iterations {
                    try await mutex.withLock {
                        await counter.increment()
                    }
                }
            }
        }
        try await group.waitForAll()
    }

    let value = await counter.value
    #expect(value == iterations * workers)
}

@Test func unfairLockNoLostUpdatesUnderContention() async {
    let lock = UnfairLock()
    let iterations = 500
    let workers = 8
    // Use a class box so concurrent tasks share one counter under the lock.
    final class Box: @unchecked Sendable {
        var value = 0
    }
    let box = Box()

    await withTaskGroup(of: Void.self) { group in
        for _ in 0..<workers {
            group.addTask {
                for _ in 0..<iterations {
                    lock.withLock {
                        box.value += 1
                    }
                }
            }
        }
    }

    #expect(box.value == iterations * workers)
}

// MARK: - Helpers

private actor AdversarialCounter {
    private(set) var value = 0
    func increment() { value += 1 }
}
