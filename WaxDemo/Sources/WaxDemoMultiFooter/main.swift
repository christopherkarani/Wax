import Foundation
import WaxCore

@main
struct WaxDemoMultiFooter {
    static func main() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("wax-demo-multi-\(UUID().uuidString)")
            .appendingPathExtension("mv2s")

        defer { try? FileManager.default.removeItem(at: url) }

        FileManager.default.createFile(atPath: url.path, contents: nil)

        print("File:", url.path)

        let lock = try FileLock.acquire(at: url, mode: .exclusive)
        defer { try? lock.release() }

        let file = try FDFile.create(at: url)
        defer { try? file.close() }

        let walOffset = Constants.walOffset
        let walSize: UInt64 = 4096

        let tocBody1 = Data("wax demo toc body v1".utf8)
        let tocBytes1 = buildTocBytes(body: tocBody1)
        let tocChecksum1 = Data(tocBytes1.suffix(32))

        let tocOffset1 = walOffset + walSize
        let footerOffset1 = tocOffset1 + UInt64(tocBytes1.count)

        let footer1 = WaxFooter(
            tocLen: UInt64(tocBytes1.count),
            tocHash: tocChecksum1,
            generation: 1,
            walCommittedSeq: 1
        )

        let header = WaxHeaderPage(
            headerPageGeneration: 1,
            fileGeneration: 1,
            footerOffset: footerOffset1,
            walOffset: walOffset,
            walSize: walSize,
            walWritePos: 0,
            walCheckpointPos: 0,
            walCommittedSeq: 1,
            tocChecksum: tocChecksum1
        )

        let page = try header.encodeWithChecksum()
        try file.writeAll(page, at: 0)
        try file.writeAll(page, at: UInt64(Constants.headerPageSize))

        try file.writeAll(tocBytes1, at: tocOffset1)
        try file.writeAll(try footer1.encode(), at: footerOffset1)

        // Second valid footer with higher generation appended later.
        let tocBody2 = Data("wax demo toc body v2 -- higher generation".utf8)
        let tocBytes2 = buildTocBytes(body: tocBody2)
        let tocChecksum2 = Data(tocBytes2.suffix(32))

        let tocOffset2 = footerOffset1 + UInt64(WaxFooter.size) + 64
        let footerOffset2 = tocOffset2 + UInt64(tocBytes2.count)

        let footer2 = WaxFooter(
            tocLen: UInt64(tocBytes2.count),
            tocHash: tocChecksum2,
            generation: 2,
            walCommittedSeq: 2
        )

        try file.writeAll(tocBytes2, at: tocOffset2)
        try file.writeAll(try footer2.encode(), at: footerOffset2)
        try file.fsync()

        let slice = try FooterScanner.findLastValidFooter(in: url)
        guard let slice else {
            throw WaxError.invalidFooter(reason: "no valid footer found in multi-footer demo")
        }

        print("Selected generation:", slice.footer.generation)
        print("Expected generation:", 2)
        print("Footer offset:", slice.footerOffset)
        print("OK")

        if slice.footer.generation != 2 {
            throw WaxError.invalidFooter(reason: "expected generation 2, got \(slice.footer.generation)")
        }
    }

    private static func buildTocBytes(body: Data) -> Data {
        var hasher = SHA256Checksum()
        hasher.update(body)
        hasher.update(Data(repeating: 0, count: 32))
        let checksum = hasher.finalize()

        var tocBytes = Data()
        tocBytes.append(body)
        tocBytes.append(checksum)
        return tocBytes
    }
}

