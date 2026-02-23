import Foundation
import WaxCore

@main
struct WaxDemoCorruptTOC {
    static func main() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("wax-demo-corrupt-\(UUID().uuidString)")
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

        let tocBody = Data("wax demo toc body".utf8)
        let tocBytes = buildTocBytes(body: tocBody)
        let tocChecksum = Data(tocBytes.suffix(32))

        let tocOffset = walOffset + walSize
        let footerOffset = tocOffset + UInt64(tocBytes.count)

        let footer = WaxFooter(
            tocLen: UInt64(tocBytes.count),
            tocHash: tocChecksum,
            generation: 1,
            walCommittedSeq: 1
        )

        let header = WaxHeaderPage(
            headerPageGeneration: 1,
            fileGeneration: 1,
            footerOffset: footerOffset,
            walOffset: walOffset,
            walSize: walSize,
            walWritePos: 0,
            walCheckpointPos: 0,
            walCommittedSeq: 1,
            tocChecksum: tocChecksum
        )

        let page = try header.encodeWithChecksum()
        try file.writeAll(page, at: 0)
        try file.writeAll(page, at: UInt64(Constants.headerPageSize))
        try file.writeAll(tocBytes, at: tocOffset)
        try file.writeAll(try footer.encode(), at: footerOffset)
        try file.fsync()

        // Corrupt the TOC body after the footer has been written.
        var corruptByte = try file.readExactly(length: 1, at: tocOffset)
        corruptByte[0] ^= 0xFF
        try file.writeAll(corruptByte, at: tocOffset)
        try file.fsync()

        let slice = try FooterScanner.findLastValidFooter(in: url)
        if slice == nil {
            print("OK: footer rejected after TOC corruption")
            return
        }

        throw WaxError.invalidFooter(reason: "expected no valid footer after TOC corruption")
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

