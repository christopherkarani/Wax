import Foundation
import Testing
@testable import WaxCore

private func fileSize(_ url: URL) throws -> UInt64 {
    let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
    return (attributes[.size] as? NSNumber)?.uint64Value ?? 0
}

// MARK: - Batch payload writes surface I/O errors

@Test func putBatchSurfacesPayloadWriteFailureAndStaysUsable() async throws {
    let url = TempFiles.uniqueURL()
    defer { try? FileManager.default.removeItem(at: url) }

    let wax = try await Wax.create(at: url)
    let contents = [Data("first".utf8), Data("second".utf8)]
    let options = [FrameMetaSubset(), FrameMetaSubset()]

    // The batch payload write must go through checked pwrite (the first write of the
    // batch), so the injected I/O error fails it before anything touches the file. A
    // mapped write would first grow the file with ftruncate and could raise SIGBUS
    // instead of throwing when the disk is full.
    let sizeBefore = try fileSize(url)
    await wax.installFileFaultPlanForTesting(FDFileFaultPlan(pwrite: [.eio]))
    await #expect(throws: WaxError.self) {
        _ = try await wax.putBatch(contents, options: options)
    }
    await wax.installFileFaultPlanForTesting(nil)
    #expect(try fileSize(url) == sizeBefore)

    let ids = try await wax.putBatch(contents, options: options)
    try await wax.commit()
    #expect(ids == [0, 1])
    #expect(try await wax.frameContent(frameId: 0) == contents[0])
    #expect(try await wax.frameContent(frameId: 1) == contents[1])
    try await wax.close()
}

// MARK: - Create never truncates an existing store

@Test func createRefusesToTruncateExistingStore() async throws {
    let url = TempFiles.uniqueURL()
    defer { try? FileManager.default.removeItem(at: url) }

    let wax = try await Wax.create(at: url)
    let payload = Data("keep me".utf8)
    _ = try await wax.put(payload)
    try await wax.commit()
    try await wax.close()
    let sizeBefore = try fileSize(url)

    await #expect(throws: WaxError.self) {
        _ = try await Wax.create(at: url)
    }

    #expect(try fileSize(url) == sizeBefore)
    let reopened = try await Wax.open(at: url)
    #expect(try await reopened.frameContent(frameId: 0) == payload)
    try await reopened.close()
}

@Test func createAcceptsPreexistingEmptyFile() async throws {
    let url = TempFiles.uniqueURL()
    defer { try? FileManager.default.removeItem(at: url) }
    #expect(FileManager.default.createFile(atPath: url.path, contents: Data()))

    let wax = try await Wax.create(at: url)
    _ = try await wax.put(Data("fresh".utf8))
    try await wax.commit()
    try await wax.close()
    #expect(try fileSize(url) > 0)
}

// MARK: - Lock waits are bounded by default

@Test func waxOptionsDefaultLockWaitTimeoutIsBounded() throws {
    let timeout = try #require(WaxOptions().lockWaitTimeout)
    #expect(timeout > .zero)
    #expect(timeout <= .seconds(60))
}

@Test func waxOptionsDefaultLockWaitMatchesFileLockDefault() {
    #expect(WaxOptions().lockWaitTimeout == FileLock.defaultAcquireTimeout)
}

@Test(.timeLimit(.minutes(1)))
func fileLockUpgradeTimesOutWhileAnotherSharedHolderExists() throws {
    try TempFiles.withTempFile { url in
        #expect(FileManager.default.createFile(atPath: url.path, contents: Data()))
        let mine = try FileLock.acquire(at: url, mode: .shared, timeout: .seconds(5))
        let other = try FileLock.acquire(at: url, mode: .shared, timeout: .seconds(5))
        defer {
            try? other.release()
            try? mine.release()
        }
        #expect(throws: WaxError.self) {
            try mine.upgrade(timeout: .milliseconds(100))
        }

        // A failed upgrade must leave the shared lock held (Linux flock drops it on a
        // failed conversion unless it is re-taken).
        #expect(mine.mode == .shared)
        try other.release()
        let intruder = try FileLock.tryAcquire(at: url, mode: .exclusive)
        #expect(intruder == nil)
        try intruder?.release()
    }
}

@Test func directorySyncTreatsOnlyUnsupportedErrnosAsSuccess() {
    #expect(FDFile.isDirectorySyncUnsupported(EINVAL))
    #expect(FDFile.isDirectorySyncUnsupported(ENOTSUP))
    #expect(!FDFile.isDirectorySyncUnsupported(EIO))
    #expect(!FDFile.isDirectorySyncUnsupported(EACCES))
}

@Test func fdFileChunksReadsAndWritesLargerThanTheIOLimit() throws {
    try TempFiles.withTempFile { url in
        let file = try FDFile.create(at: url, ioChunkLimit: 3)
        defer { try? file.close() }
        let payload = Data((0..<20).map { UInt8($0) })
        try file.writeAll(payload, at: 5)
        #expect(try file.readExactly(length: payload.count, at: 5) == payload)
        #expect(try file.size() == 25)
    }
}

@Test func putBatchPayloadWritesPrecedeTheDurableAnchorFsync() async throws {
    let url = TempFiles.uniqueURL()
    defer { try? FileManager.default.removeItem(at: url) }
    let created = try await Wax.create(at: url)
    _ = try await created.put(Data("seed".utf8))
    try await created.commit()
    try await created.close()

    // A reopened store's WAL needs a durable anchor: its first append fsyncs the whole
    // file before writing the first record. The batch payloads must already be written
    // by then, or that fsync would not cover them.
    let wax = try await Wax.open(at: url)
    await wax.installFileFaultPlanForTesting(FDFileFaultPlan(recordsOperations: true))
    let contents = [Data(repeating: 1, count: 777), Data(repeating: 2, count: 1333)]
    let ids = try await wax.putBatch(contents, options: contents.map { _ in FrameMetaSubset() })
    let operations = await wax.recordedFileOperationsForTesting()
    await wax.installFileFaultPlanForTesting(nil)

    let metas = await wax.frameMetasIncludingPending(frameIds: ids)
    let payloadWrites: [FDFileOperation] = try ids.map { id in
        let meta = try #require(metas[id])
        return .pwrite(offset: meta.payloadOffset, length: Int(meta.payloadLength))
    }
    let payloadIndices = try payloadWrites.map { try #require(operations.firstIndex(of: $0)) }
    let firstFsync = try #require(operations.firstIndex(of: .fsync))
    #expect(payloadIndices.allSatisfy { $0 < firstFsync })
    // The anchor really ran: WAL records were written after that fsync.
    #expect(operations[(firstFsync + 1)...].contains { if case .pwrite = $0 { true } else { false } })

    try await wax.commit()
    for (id, content) in zip(ids, contents) {
        #expect(try await wax.frameContent(frameId: id) == content)
    }
    try await wax.close()
}

@Test func putBatchWritesEachPayloadAtContiguousOffsets() async throws {
    let url = TempFiles.uniqueURL()
    defer { try? FileManager.default.removeItem(at: url) }
    let wax = try await Wax.create(at: url)
    let contents = [Data("alpha".utf8), Data(), Data(repeating: 9, count: 4096), Data("omega".utf8)]
    let ids = try await wax.putBatch(contents, options: contents.map { _ in FrameMetaSubset() })
    try await wax.commit()
    for (id, content) in zip(ids, contents) {
        #expect(try await wax.frameContent(frameId: id) == content)
    }
    try await wax.close()
}

// MARK: - Directory durability

@Test func fsyncParentDirectorySucceedsForCreatedFile() throws {
    try TempFiles.withTempFile { url in
        #expect(FileManager.default.createFile(atPath: url.path, contents: Data("x".utf8)))
        try FDFile.fsyncParentDirectory(of: url)
    }
}

@Test func fsyncParentDirectoryThrowsForMissingDirectory() {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString)
        .appendingPathComponent("store.wax")
    #expect(throws: WaxError.self) {
        try FDFile.fsyncParentDirectory(of: url)
    }
}

// MARK: - FDFile close state is lock-guarded

@Test func fdFileCloseStateRacesReadsSafely() async throws {
    let url = TempFiles.uniqueURL()
    defer { try? FileManager.default.removeItem(at: url) }
    let file = try FDFile.create(at: url)

    // `isClosed` is read by every I/O call and written by `close()`; it is now read
    // under `closeLock` (run under TSan to see the race on the old unguarded read).
    await withTaskGroup(of: Void.self) { group in
        for _ in 0..<4 {
            group.addTask {
                for _ in 0..<200 {
                    _ = try? file.size()
                    _ = file.isClosed
                }
            }
        }
        group.addTask { try? file.close() }
    }
    #expect(file.isClosed)
}
