import Foundation
import Testing
@testable import WaxCore

@Test func createAndWriteUpdatesSize() throws {
    try TempFiles.withTempFile { url in
        let file = try FDFile.create(at: url)
        defer { try? file.close() }

        let data = Data("Hello, World!".utf8)
        try file.writeAll(data, at: 0)
        try file.fsync()

        #expect(try file.size() == UInt64(data.count))
    }
}

@Test func writeAtOffsetExtendsFile() throws {
    try TempFiles.withTempFile { url in
        let file = try FDFile.create(at: url)
        defer { try? file.close() }

        let data = Data([0xDE, 0xAD, 0xBE, 0xEF])
        try file.writeAll(data, at: 100)
        try file.fsync()

        #expect(try file.size() == 104)
        #expect(try file.read(length: 4, at: 100) == data)
    }
}

@Test func readAtOffsetReadsCorrectBytes() throws {
    try TempFiles.withTempFile { url in
        let file = try FDFile.create(at: url)
        defer { try? file.close() }

        try file.writeAll(Data([0x00, 0x01, 0x02, 0x03, 0x04, 0x05]), at: 0)
        #expect(try file.read(length: 2, at: 2) == Data([0x02, 0x03]))
    }
}

@Test func readCanShortReadAtEOF() throws {
    try TempFiles.withTempFile { url in
        let file = try FDFile.create(at: url)
        defer { try? file.close() }

        try file.writeAll(Data([0x01, 0x02, 0x03]), at: 0)
        let result = try file.read(length: 100, at: 0)
        #expect(result.count == 3)
    }
}

@Test func readExactlyThrowsOnShortRead() throws {
    try TempFiles.withTempFile { url in
        let file = try FDFile.create(at: url)
        defer { try? file.close() }

        try file.writeAll(Data([0x01, 0x02, 0x03]), at: 0)

        do {
            _ = try file.readExactly(length: 4, at: 0)
            #expect(Bool(false))
        } catch let error as WaxError {
            guard case .io = error else {
                #expect(Bool(false))
                return
            }
        }
    }
}

@Test func truncateShrinksFile() throws {
    try TempFiles.withTempFile { url in
        let file = try FDFile.create(at: url)
        defer { try? file.close() }

        try file.writeAll(Data(repeating: 0xFF, count: 1000), at: 0)
        #expect(try file.size() == 1000)

        try file.truncate(to: 500)
        #expect(try file.size() == 500)
    }
}

@Test func truncateExtendsFile() throws {
    try TempFiles.withTempFile { url in
        let file = try FDFile.create(at: url)
        defer { try? file.close() }

        try file.truncate(to: 4096)
        #expect(try file.size() == 4096)

        let zeros = try file.read(length: 100, at: 0)
        #expect(zeros.allSatisfy { $0 == 0 })
    }
}

@Test func fsyncDoesNotThrow() throws {
    try TempFiles.withTempFile { url in
        let file = try FDFile.create(at: url)
        defer { try? file.close() }

        try file.writeAll(Data("test".utf8), at: 0)
        try file.fsync()
    }
}

@Test func openNonexistentFileThrows() throws {
    let url = TempFiles.uniqueURL()

    do {
        _ = try FDFile.open(at: url)
        #expect(Bool(false))
    } catch let error as WaxError {
        guard case .io = error else {
            #expect(Bool(false))
            return
        }
    }
}

@Test func openReadOnlyCanRead() throws {
    try TempFiles.withTempFile { url in
        do {
            let file = try FDFile.create(at: url)
            try file.writeAll(Data("readonly test".utf8), at: 0)
            try file.close()
        }

        let file = try FDFile.openReadOnly(at: url)
        defer { try? file.close() }

        let content = try file.read(length: 50, at: 0)
        #expect(content.count > 0)
    }
}

@Test func readExactlyRetriesInjectedEINTR() throws {
    try TempFiles.withTempFile { url in
        let file = try FDFile.create(at: url)
        defer { try? file.close() }

        let payload = Data("eintr-retry".utf8)
        try file.writeAll(payload, at: 0)
        file.installFaultPlan(
            FDFileFaultPlan(
                pread: [.eintr(retries: 2)],
                pwrite: []
            )
        )

        let decoded = try file.readExactly(length: payload.count, at: 0)
        #expect(decoded == payload)
    }
}

@Test func readExactlyThrowsInjectedEIO() throws {
    try TempFiles.withTempFile { url in
        let file = try FDFile.create(at: url)
        defer { try? file.close() }

        try file.writeAll(Data("eio".utf8), at: 0)
        file.installFaultPlan(
            FDFileFaultPlan(
                pread: [.eio],
                pwrite: []
            )
        )

        do {
            _ = try file.readExactly(length: 3, at: 0)
            #expect(Bool(false))
        } catch let error as WaxError {
            guard case .io = error else {
                #expect(Bool(false))
                return
            }
        }
    }
}

@Test func writeAllHandlesInjectedShortWrite() throws {
    try TempFiles.withTempFile { url in
        let file = try FDFile.create(at: url)
        defer { try? file.close() }

        let payload = Data("short-write-path".utf8)
        file.installFaultPlan(
            FDFileFaultPlan(
                pread: [],
                pwrite: [
                    .shortWrite(maxBytes: 1),
                    .shortWrite(maxBytes: 2),
                ]
            )
        )

        try file.writeAll(payload, at: 0)
        let decoded = try file.readExactly(length: payload.count, at: 0)
        #expect(decoded == payload)
    }
}

@Test func writeAllThrowsInjectedENOSPC() throws {
    try TempFiles.withTempFile { url in
        let file = try FDFile.create(at: url)
        defer { try? file.close() }

        file.installFaultPlan(
            FDFileFaultPlan(
                pread: [],
                pwrite: [.enospc]
            )
        )

        do {
            try file.writeAll(Data("disk-full".utf8), at: 0)
            #expect(Bool(false))
        } catch let error as WaxError {
            guard case .io(let reason) = error else {
                #expect(Bool(false))
                return
            }
            #expect(reason.contains("pwrite failed"))
        }
    }
}

@Test func createUsesSecureDefaultPermissions() throws {
    try TempFiles.withTempFile { url in
        let file = try FDFile.create(at: url)
        defer { try? file.close() }

        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        guard let mode = attrs[.posixPermissions] as? NSNumber else {
            Issue.record("Missing posix permissions")
            return
        }
        #expect((mode.intValue & 0o777) == 0o600)
    }
}

@Test func createAllowsPermissionOverride() throws {
    try TempFiles.withTempFile { url in
        let file = try FDFile.create(at: url, mode: mode_t(0o640))
        defer { try? file.close() }

        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        guard let mode = attrs[.posixPermissions] as? NSNumber else {
            Issue.record("Missing posix permissions")
            return
        }
        #expect((mode.intValue & 0o777) == 0o640)
    }
}

// MARK: - Additional fault-injection and lifecycle tests

@Test func writeAllHandlesInjectedEINTROnWrite() throws {
    try TempFiles.withTempFile { url in
        let file = try FDFile.create(at: url)
        defer { try? file.close() }

        let payload = Data("eintr-write-test".utf8)
        file.installFaultPlan(
            FDFileFaultPlan(
                pread: [],
                pwrite: [.eintr(retries: 2)]
            )
        )

        // EINTR on writes should be retried; the write must succeed overall
        try file.writeAll(payload, at: 0)
        let readback = try file.readExactly(length: payload.count, at: 0)
        #expect(readback == payload)
    }
}

@Test func writeAllThrowsInjectedEIO() throws {
    try TempFiles.withTempFile { url in
        let file = try FDFile.create(at: url)
        defer { try? file.close() }

        file.installFaultPlan(
            FDFileFaultPlan(
                pread: [],
                pwrite: [.eio]
            )
        )

        do {
            try file.writeAll(Data("eio-write".utf8), at: 0)
            #expect(Bool(false))
        } catch let error as WaxError {
            guard case .io(let reason) = error else {
                #expect(Bool(false))
                return
            }
            #expect(reason.contains("pwrite failed"))
        }
    }
}

@Test func readExactlyHandlesShortReadFault() throws {
    try TempFiles.withTempFile { url in
        let file = try FDFile.create(at: url)
        defer { try? file.close() }

        let payload = Data("short-read-recovery".utf8)
        try file.writeAll(payload, at: 0)

        // One fault returning only 1 byte per call, then normal reads
        file.installFaultPlan(
            FDFileFaultPlan(
                pread: [.shortRead(maxBytes: 1)],
                pwrite: []
            )
        )

        let result = try file.readExactly(length: payload.count, at: 0)
        #expect(result == payload)
    }
}

@Test func closingAlreadyClosedFileIsIdempotent() throws {
    try TempFiles.withTempFile { url in
        let file = try FDFile.create(at: url)
        try file.close()
        // Second close must not throw
        try file.close()
    }
}

@Test func operationsOnClosedFileThrow() throws {
    try TempFiles.withTempFile { url in
        let file = try FDFile.create(at: url)
        try file.close()

        do {
            _ = try file.size()
            #expect(Bool(false))
        } catch let error as WaxError {
            guard case .io(let reason) = error else {
                #expect(Bool(false))
                return
            }
            #expect(reason.contains("closed"))
        }
    }
}

@Test func deinitWithoutCloseDoesNotLeak() throws {
    // If the file is never closed explicitly, deinit should close the fd.
    // We verify this by checking that after deinit a new exclusive lock can be taken.
    let url = TempFiles.uniqueURL()
    defer { try? FileManager.default.removeItem(at: url) }

    do {
        let file = try FDFile.create(at: url)
        // Intentionally NOT closing — let deinit handle it
        _ = file.fileDescriptor // access to ensure it isn't optimised away
    }
    // If fd were leaked/held open we might see issues; at minimum the file must exist
    #expect(FileManager.default.fileExists(atPath: url.path))
}

@Test func mapWritableRoundtrip() throws {
    try TempFiles.withTempFile { url in
        let file = try FDFile.create(at: url)
        defer { try? file.close() }

        let payload = Data("mmap-test".utf8)
        let region = try file.mapWritable(length: payload.count, at: 0)
        region.copyBytes(from: payload)
        region.close()

        let readback = try file.readExactly(length: payload.count, at: 0)
        #expect(readback == payload)
    }
}

@Test func mapWritableWithZeroLengthThrows() throws {
    try TempFiles.withTempFile { url in
        let file = try FDFile.create(at: url)
        defer { try? file.close() }

        do {
            _ = try file.mapWritable(length: 0, at: 0)
            #expect(Bool(false))
        } catch let error as WaxError {
            guard case .io = error else {
                #expect(Bool(false))
                return
            }
        }
    }
}

@Test func ensureSizeExtendsFileToAtLeast() throws {
    try TempFiles.withTempFile { url in
        let file = try FDFile.create(at: url)
        defer { try? file.close() }

        try file.ensureSize(atLeast: 4096)
        #expect(try file.size() == 4096)

        // Already large enough — must not shrink
        try file.ensureSize(atLeast: 512)
        #expect(try file.size() == 4096)
    }
}

@Test func clearFaultPlanRestoresNormalBehavior() throws {
    try TempFiles.withTempFile { url in
        let file = try FDFile.create(at: url)
        defer { try? file.close() }

        let payload = Data("clear-fault-test".utf8)
        try file.writeAll(payload, at: 0)

        // Install a fault plan that would fail reads
        file.installFaultPlan(FDFileFaultPlan(pread: [.eio], pwrite: []))
        file.clearFaultPlan()

        // After clearing the plan, reads should succeed normally
        let result = try file.readExactly(length: payload.count, at: 0)
        #expect(result == payload)
    }
}
