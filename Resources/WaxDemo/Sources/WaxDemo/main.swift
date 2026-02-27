import Foundation
import WaxCore

private enum DemoError: Error, CustomStringConvertible {
    case usage(String)

    var description: String {
        switch self {
        case .usage(let msg): return msg
        }
    }
}

private struct DemoOptions {
    var keepFile: Bool = false
    var corruptHeaderB: Bool = false
    var appendCorruptFooter: Bool = false
}

private func parseArgs(_ args: [String]) throws -> DemoOptions {
    var options = DemoOptions()
    var i = 0
    while i < args.count {
        switch args[i] {
        case "--keep":
            options.keepFile = true
        case "--corrupt-header-b":
            options.corruptHeaderB = true
        case "--append-corrupt-footer":
            options.appendCorruptFooter = true
        case "--help", "-h":
            throw DemoError.usage(usage())
        default:
            throw DemoError.usage("Unknown arg: \(args[i])\n\n\(usage())")
        }
        i += 1
    }
    return options
}

private func usage() -> String {
    """
    WaxDemo (Phase 0–2 validation)

    Usage:
      swift run WaxDemo [--keep] [--corrupt-header-b] [--append-corrupt-footer]

    Flags:
      --keep                 Keep the generated .wax file (prints its path)
      --corrupt-header-b     Corrupt header page B to prove A/B selection behavior
      --append-corrupt-footer Append a trailing corrupt footer to prove scanner finds prior valid one
    """
}

@main
struct WaxDemoMain {
    static func main() throws {
        let options = try parseArgs(Array(CommandLine.arguments.dropFirst()))
        try run(options: options)
    }

    private static func run(options: DemoOptions) throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("wax-demo-\(UUID().uuidString)")
            .appendingPathExtension("wax")

        defer {
            if !options.keepFile {
                try? FileManager.default.removeItem(at: url)
            }
        }

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

        let headerA = WaxHeaderPage(
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

        let headerB = WaxHeaderPage(
            headerPageGeneration: 2,
            fileGeneration: 1,
            footerOffset: footerOffset,
            walOffset: walOffset,
            walSize: walSize,
            walWritePos: 0,
            walCheckpointPos: 0,
            walCommittedSeq: 1,
            tocChecksum: tocChecksum
        )

        let pageA = try headerA.encodeWithChecksum()
        var pageB = try headerB.encodeWithChecksum()
        if options.corruptHeaderB {
            pageB[200] ^= 0xFF
        }

        try file.writeAll(pageA, at: 0)
        try file.writeAll(pageB, at: UInt64(Constants.headerPageSize))

        try file.writeAll(tocBytes, at: tocOffset)
        try file.writeAll(try footer.encode(), at: footerOffset)

        if options.appendCorruptFooter {
            var badFooter = try footer.encode()
            badFooter[10] ^= 0xFF
            let badOffset = footerOffset + UInt64(WaxFooter.size) + 123
            try file.writeAll(tocBytes, at: badOffset - UInt64(tocBytes.count))
            try file.writeAll(badFooter, at: badOffset)
        }

        try file.fsync()

        let ro = try FDFile.openReadOnly(at: url)
        defer { try? ro.close() }

        let readA = try ro.readExactly(length: WaxHeaderPage.size, at: 0)
        let readB = try ro.readExactly(length: WaxHeaderPage.size, at: Constants.headerPageSize)

        if let selected = WaxHeaderPage.selectValidPage(pageA: readA, pageB: readB) {
            print("Selected header page:", selected.pageIndex == 0 ? "A" : "B")
            print("Header footer_offset:", selected.page.footerOffset)
            print("Header wal_offset:", selected.page.walOffset)
            print("Header wal_size:", selected.page.walSize)
            print("Header toc_checksum matches:", selected.page.tocChecksum == tocChecksum)
        } else {
            print("Selected header page: none (both invalid)")
        }

        let slice = try FooterScanner.findLastValidFooter(in: url)
        guard let slice else {
            throw WaxError.invalidFooter(reason: "no valid footer found (bounded scan)")
        }

        print("Footer generation:", slice.footer.generation)
        print("Footer offset:", slice.footerOffset)
        print("TOC offset:", slice.tocOffset)
        print("TOC bytes length:", slice.tocBytes.count)
        print("Footer toc_hash matches toc bytes:", slice.footer.hashMatches(tocBytes: slice.tocBytes))
        print("OK")
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
