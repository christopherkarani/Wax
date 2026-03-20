import Foundation
import WaxCore

/// Minimal public frame-level facade for packages that need durable payload storage
/// without depending on WaxCore package internals.
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

    public func close() async {
        await session.close()
    }

    @discardableResult
    public func put(
        _ content: Data,
        kind: String,
        metadata: [String: String] = [:]
    ) async throws -> UInt64 {
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

    public func frames() async -> [Frame] {
        await wax.frameMetas().map(Frame.init(meta:))
    }

    public func content(frameID: UInt64) async throws -> Data {
        try await wax.frameContent(frameId: frameID)
    }

    public func delete(frameID: UInt64) async throws {
        try await wax.delete(frameId: frameID)
        try await wax.commit()
    }
}
