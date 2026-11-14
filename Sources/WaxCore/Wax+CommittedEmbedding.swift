import Foundation

/// The embedder binding and vector count a store's last commit recorded.
package struct CommittedEmbeddingState: Equatable, Sendable {
    package let binding: MemoryBinding?
    package let vectorCount: UInt64

    package init(binding: MemoryBinding?, vectorCount: UInt64) {
        self.binding = binding
        self.vectorCount = vectorCount
    }
}

extension Wax {
    /// Reads the binding and vector count of a store's last commit without taking its lock or
    /// repairing anything, so it is safe on a store another process holds open. Vectors still
    /// in the WAL are not counted. Returns `nil` for a missing store or one with no valid
    /// header page or commit.
    package static func committedEmbeddingState(at url: URL) throws -> CommittedEmbeddingState? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let header: WaxHeaderPage
        do {
            let file = try FDFile.openReadOnly(at: url)
            defer { try? file.close() }
            let pageA = try file.readExactly(length: Int(Constants.headerPageSize), at: 0)
            let pageB = try file.readExactly(length: Int(Constants.headerPageSize), at: Constants.headerPageSize)
            guard let selected = WaxHeaderPage.selectValidPage(pageA: pageA, pageB: pageB) else { return nil }
            header = selected.page
        }
        let footer = try FooterScanner.findFooter(at: header.footerOffset, in: url)
            ?? FooterScanner.findLastValidFooter(in: url, accepts: header.admitsRecovery)
        guard let footer else { return nil }
        let toc = try WaxTOC.decode(from: footer)
        return CommittedEmbeddingState(
            binding: toc.memoryBinding,
            vectorCount: toc.indexes.vec?.vectorCount ?? 0
        )
    }
}
