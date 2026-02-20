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
