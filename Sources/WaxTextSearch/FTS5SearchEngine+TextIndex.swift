import Foundation
@preconcurrency import GRDB
import WaxCore

extension FTS5SearchEngine {
    package func index(frameId: UInt64, text: String) async throws {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            try await remove(frameId: frameId)
            return
        }
        let frameIdValue = try Self.toInt64(frameId)
        enqueuePendingOp(frameIdValue: frameIdValue, op: .upsert(trimmed))
        try await flushPendingOpsIfThresholdExceeded()
    }

    /// Batch index multiple frames in a single database transaction.
    /// This amortizes transaction overhead and actor hops across all documents.
    package func indexBatch(frameIds: [UInt64], texts: [String]) async throws {
        guard !frameIds.isEmpty else { return }
        guard frameIds.count == texts.count else {
            throw WaxError.encodingError(reason: "indexBatch: frameIds.count != texts.count")
        }

        for (frameId, text) in zip(frameIds, texts) {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            let frameIdValue = try Self.toInt64(frameId)
            if trimmed.isEmpty {
                enqueuePendingOp(frameIdValue: frameIdValue, op: .delete)
            } else {
                enqueuePendingOp(frameIdValue: frameIdValue, op: .upsert(trimmed))
            }
        }
        try await flushPendingOpsIfThresholdExceeded()
    }

    package func remove(frameId: UInt64) async throws {
        let frameIdValue = try Self.toInt64(frameId)
        enqueuePendingOp(frameIdValue: frameIdValue, op: .delete)
        try await flushPendingOpsIfThresholdExceeded()
    }

    package func removeInactiveFrames(_ metas: [FrameMeta]) async throws {
        let inactiveFrameIds = try metas.compactMap { meta -> Int64? in
            guard meta.status == .deleted || meta.supersededBy != nil else { return nil }
            return try Self.toInt64(meta.id)
        }
        guard !inactiveFrameIds.isEmpty else { return }

        try await flushPendingOpsIfNeeded()
        let dbQueue = self.dbQueue
        let removedCount = try await io.run {
            try dbQueue.write { db in
                let deleteFramesStmt = try db.makeStatement(sql: """
                    DELETE FROM frames_fts
                    WHERE rowid IN (SELECT rowid_ref FROM frame_mapping WHERE frame_id = ?)
                    """)
                let deleteMappingStmt = try db.makeStatement(sql: """
                    DELETE FROM frame_mapping
                    WHERE frame_id = ?
                    """)
                var removed = 0
                for frameId in inactiveFrameIds {
                    try deleteFramesStmt.execute(arguments: [frameId])
                    try deleteMappingStmt.execute(arguments: [frameId])
                    if db.changesCount > 0 { removed += 1 }
                }
                return removed
            }
        }

        if removedCount > 0 {
            let removedU = UInt64(removedCount)
            docCount = docCount > removedU ? (docCount &- removedU) : 0
            dirty = true
        }
    }

    package func search(matchQuery: String, topK: Int) async throws -> [TextSearchResult] {
        try await flushPendingOpsIfNeeded()
        let trimmed = matchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        let limit = try Self.validatedTopK(topK)
        let dbQueue = self.dbQueue
        return try await io.run {
            try dbQueue.read { db in
                let sql = """
                    SELECT m.frame_id AS frame_id,
                           bm25(frames_fts) AS rank,
                           snippet(frames_fts, 0, '\(Self.snippetOpenMarker)', '\(Self.snippetCloseMarker)', '...', 10) AS snippet
                    FROM frames_fts
                    JOIN frame_mapping m ON m.rowid_ref = frames_fts.rowid
                    WHERE frames_fts MATCH ?
                    ORDER BY rank ASC, m.frame_id ASC
                    LIMIT ?
                    """
                let rows = try Row.fetchAll(db, sql: sql, arguments: [trimmed, limit])
                return rows.compactMap { row in
                    guard let frameIdValue: Int64 = row["frame_id"], frameIdValue >= 0 else { return nil }
                    let rank: Double = row["rank"] ?? 0
                    let snippet: String? = row["snippet"]
                    return TextSearchResult(
                        frameId: UInt64(frameIdValue),
                        score: Self.scoreFromBM25Rank(rank),
                        snippet: snippet
                    )
                }
            }
        }
    }

    private func enqueuePendingOp(frameIdValue: Int64, op: PendingOp) {
        if pendingOps[frameIdValue] == nil {
            pendingKeys.append(frameIdValue)
        }
        pendingOps[frameIdValue] = op
        dirty = true
    }

    private func flushPendingOpsIfThresholdExceeded() async throws {
        guard pendingOps.count >= Self.flushThreshold else { return }
        try await flushPendingOpsIfNeeded()
    }

    func flushPendingOpsIfNeeded() async throws {
        guard !pendingOps.isEmpty else {
            if !pendingStructuredOps.isEmpty {
                try await flushPendingStructuredOpsIfNeeded()
            }
            return
        }

        let ops = pendingOps
        let keys = pendingKeys
        let dbQueue = self.dbQueue

        let (addedCount, removedCount) = try await io.run { () throws -> (added: Int, removed: Int) in
            var added = 0
            var removed = 0

            try dbQueue.write { db in
                let deleteFramesStmt = try db.makeStatement(sql: """
                    DELETE FROM frames_fts
                    WHERE rowid IN (SELECT rowid_ref FROM frame_mapping WHERE frame_id = ?)
                    """)
                let deleteMappingStmt = try db.makeStatement(sql: """
                    DELETE FROM frame_mapping
                    WHERE frame_id = ?
                    """)
                let insertFrameStmt = try db.makeStatement(sql: """
                    INSERT INTO frames_fts(content) VALUES (?)
                    """)
                let insertMappingStmt = try db.makeStatement(sql: """
                    INSERT INTO frame_mapping(frame_id, rowid_ref) VALUES (?, ?)
                    """)

                for frameIdValue in keys {
                    guard let op = ops[frameIdValue] else { continue }

                    switch op {
                    case .upsert(let text):
                        try deleteFramesStmt.execute(arguments: [frameIdValue])
                        try deleteMappingStmt.execute(arguments: [frameIdValue])
                        let existed = db.changesCount > 0
                        if !existed { added += 1 }

                        try insertFrameStmt.execute(arguments: [text])
                        let rowid = db.lastInsertedRowID
                        try insertMappingStmt.execute(arguments: [frameIdValue, rowid])

                    case .delete:
                        try deleteFramesStmt.execute(arguments: [frameIdValue])
                        try deleteMappingStmt.execute(arguments: [frameIdValue])
                        if db.changesCount > 0 { removed += 1 }
                    }
                }
            }

            return (added, removed)
        }

        if addedCount > 0 {
            docCount &+= UInt64(addedCount)
        }
        if removedCount > 0 {
            let removedU = UInt64(removedCount)
            docCount = docCount > removedU ? (docCount &- removedU) : 0
        }

        pendingOps.removeAll(keepingCapacity: true)
        pendingKeys.removeAll(keepingCapacity: true)

        if !pendingStructuredOps.isEmpty {
            try await flushPendingStructuredOpsIfNeeded()
        }
    }
}
