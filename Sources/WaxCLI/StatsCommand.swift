import ArgumentParser
import Foundation
import Wax

struct StatsCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "stats",
        abstract: "Show Wax memory store statistics"
    )

    @OptionGroup var store: StoreOptions

    func runAsync() async throws {
        // Stats does not need the embedder; force noEmbedder to skip MiniLM loading.
        let url = try StoreSession.resolveURL(store.storePath)
        let memory = try await StoreSession.open(at: url, noEmbedder: true)
        defer { Task { try? await memory.close() } }

        let stats = await memory.runtimeStats()
        let sessionStats = try await memory.sessionRuntimeStats()

        let diskBytes: UInt64 = {
            guard let attrs = try? FileManager.default.attributesOfItem(atPath: stats.storeURL.path),
                  let size = attrs[FileAttributeKey.size] as? NSNumber
            else {
                return 0
            }
            return size.uint64Value
        }()

        switch store.format {
        case .json:
            var embedder: Any = NSNull()
            if let identity = stats.embedderIdentity {
                embedder = [
                    "provider": identity.provider ?? "",
                    "model": identity.model ?? "",
                    "dimensions": identity.dimensions ?? 0,
                    "normalized": identity.normalized ?? false,
                ] as [String: Any]
            }

            printJSON([
                "frameCount": stats.frameCount,
                "pendingFrames": stats.pendingFrames,
                "generation": stats.generation,
                "diskBytes": diskBytes,
                "storePath": stats.storeURL.path,
                "vectorSearchEnabled": stats.vectorSearchEnabled,
                "features": [
                    "structuredMemoryEnabled": stats.structuredMemoryEnabled,
                    "accessStatsScoringEnabled": stats.accessStatsScoringEnabled,
                ],
                "embedder": embedder,
                "wal": [
                    "walSize": stats.wal.walSize,
                    "writePos": stats.wal.writePos,
                    "checkpointPos": stats.wal.checkpointPos,
                    "pendingBytes": stats.wal.pendingBytes,
                    "committedSeq": stats.wal.committedSeq,
                    "lastSeq": stats.wal.lastSeq,
                    "wrapCount": stats.wal.wrapCount,
                    "checkpointCount": stats.wal.checkpointCount,
                ],
                "session": [
                    "active": sessionStats.active,
                    "session_id": sessionStats.sessionId?.uuidString ?? NSNull(),
                    "sessionFrameCount": sessionStats.sessionFrameCount,
                    "sessionTokenEstimate": sessionStats.sessionTokenEstimate,
                    "pendingFramesStoreWide": sessionStats.pendingFramesStoreWide,
                    "countsIncludePending": sessionStats.countsIncludePending,
                ],
            ])
        case .text:
            print("Store: \(stats.storeURL.path)")
            print("Frames: \(stats.frameCount) (\(stats.pendingFrames) pending)")
            print("Generation: \(stats.generation)")
            print("Disk: \(ByteCountFormatter.string(fromByteCount: Int64(diskBytes), countStyle: .file))")
            print("Vector search: \(stats.vectorSearchEnabled ? "enabled" : "disabled")")
            if let identity = stats.embedderIdentity {
                let provider = identity.provider ?? "unknown"
                let model = identity.model ?? "unknown"
                let dims = identity.dimensions.map { String($0) } ?? "?"
                print("Embedder: \(provider)/\(model) (\(dims)d)")
            } else {
                print("Embedder: none")
            }
            print("WAL: \(stats.wal.pendingBytes) bytes pending, seq \(stats.wal.committedSeq)-\(stats.wal.lastSeq)")
        }
    }
}

struct FlushCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "flush",
        abstract: "Flush pending writes to make frames searchable"
    )

    @OptionGroup var store: StoreOptions

    func runAsync() async throws {
        // Flush does not need the embedder; skip MiniLM loading.
        let url = try StoreSession.resolveURL(store.storePath)
        let memory = try await StoreSession.open(at: url, noEmbedder: true)
        defer { Task { try? await memory.close() } }

        try await memory.flush()
        let stats = await memory.runtimeStats()

        switch store.format {
        case .json:
            printJSON([
                "status": "ok",
                "frameCount": stats.frameCount,
                "message": "Flushed. \(stats.frameCount) frames now searchable.",
            ])
        case .text:
            print("Flushed. \(stats.frameCount) frames now searchable.")
        }
    }
}
