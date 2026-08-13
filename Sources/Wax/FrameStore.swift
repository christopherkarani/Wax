import Foundation
import WaxCore

/// Minimal public frame-level facade for packages that need durable payload storage
/// without depending on WaxCore package internals.
///
/// `FrameStore` is the low-level payload API. ``create(at:walSize:)`` defaults
/// `walSize` to ``defaultWalSize`` (256 MiB) so CLI/MCP stores stay compatible.
/// The public ``Memory`` facade uses a 4 MiB WAL
/// (``Memory/Config-swift.struct/defaultWalSizeBytes``) for new files.
public actor FrameStore {
    public enum Status: Sendable, Equatable {
        case active
        case deleted
    }

    public struct Frame: Sendable, Equatable {
        public let id: UInt64
        public let kind: String?
        public let metadata: [String: String]
        public let status: Status
        public let supersededBy: UInt64?

        init(meta: FrameMeta) {
            self.id = meta.id
            self.kind = meta.kind
            self.metadata = meta.metadata?.entries ?? [:]
            self.status = switch meta.status {
            case .active:
                .active
            case .deleted:
                .deleted
            }
            self.supersededBy = meta.supersededBy
        }
    }

    public static let defaultWalSize: UInt64 = 256 * 1024 * 1024

    private let session: WaxSession
    private let wax: Wax
    private var isClosed = false

    private init(session: WaxSession) {
        self.session = session
        self.wax = session.wax
    }

    public static func create(
        at url: URL,
        walSize: UInt64 = defaultWalSize
    ) async throws -> FrameStore {
        let wax = try await Wax.create(at: url, walSize: walSize)
        let session = try await WaxSession(
            wax: wax,
            mode: .readWrite(),
            config: .init(
                enableTextSearch: false,
                enableVectorSearch: false,
                enableStructuredMemory: false
            )
        )
        return FrameStore(session: session)
    }

    public static func open(at url: URL) async throws -> FrameStore {
        let wax = try await Wax.open(at: url)
        let session = try await WaxSession(
            wax: wax,
            mode: .readWrite(),
            config: .init(
                enableTextSearch: false,
                enableVectorSearch: false,
                enableStructuredMemory: false
            )
        )
        return FrameStore(session: session)
    }

    /// Commit pending session state to durable storage.
    ///
    /// ``put(_:kind:metadata:)`` and ``delete(frameID:)`` already commit. This is
    /// the explicit durability barrier required of every public store owner:
    /// it stages and commits any pending session state. Safe to call more than
    /// once. Throws if the store is closed.
    public func flush() async throws {
        try ensureOpen()
        try await session.commit()
    }

    /// Close the store and release the exclusive file lock.
    ///
    /// Safe to call multiple times: a second close is a no-op.
    /// Surfaces durability errors from the underlying close/commit; `isClosed` is only set
    /// after a successful close so a failed attempt does not leave a sticky closed state that
    /// swallows the failure.
    public func close() async throws {
        guard !isClosed else { return }
        try await flush()
        await session.close()
        // Must release the underlying exclusive flock; session.close only drops the writer lease.
        try await wax.close()
        isClosed = true
    }

    @discardableResult
    public func put(
        _ content: Data,
        kind: String,
        metadata: [String: String] = [:]
    ) async throws -> UInt64 {
        try ensureOpen()
        let frameID = try await session.put(
            content,
            options: FrameMetaSubset(
                kind: kind,
                metadata: Metadata(metadata)
            ),
            compression: .plain
        )
        try await session.commit()
        return frameID
    }

    public func frames() async throws -> [Frame] {
        try ensureOpen()
        return await wax.frameMetas().map(Frame.init(meta:))
    }

    public func content(frameID: UInt64) async throws -> Data {
        try ensureOpen()
        return try await wax.frameContent(frameId: frameID)
    }

    public func delete(frameID: UInt64) async throws {
        try ensureOpen()
        try await wax.delete(frameId: frameID)
        try await wax.commit()
    }

    private func ensureOpen() throws {
        guard !isClosed else {
            throw WaxError.io("FrameStore is closed")
        }
    }
}
