import Foundation
@preconcurrency import GRDB
import WaxCore

/// Text-index coverage watermark, stored inside the lex blob.
///
/// Frames reach disk before the lex index that covers them: the WAL is replayed on open and a
/// store commit can publish frames without a staged text index. The watermark records the
/// lowest frame id whose postings the blob does not vouch for, so an open can index exactly the
/// frames a crash left behind.
///
/// The table is added without a `user_version` bump: older readers ignore it. A blob without it
/// vouches for nothing; the first catch-up scans every frame (indexed ones are skipped) and the
/// next commit records the watermark.
enum FTS5Coverage {
    private static let key = "covered_below_frame_id"

    /// The stored watermark, or `nil` for a blob written before the watermark existed.
    static func coveredBelowFrameId(in db: Database) throws -> UInt64? {
        let hasTable = try String.fetchOne(
            db,
            sql: "SELECT name FROM sqlite_master WHERE type='table' AND name='wax_lex_coverage'"
        ) != nil
        guard hasTable,
              let stored = try Int64.fetchOne(db, sql: "SELECT value FROM wax_lex_coverage WHERE key = ?", arguments: [key]),
              stored >= 0 else { return nil }
        return UInt64(stored)
    }

    static func write(coveredBelowFrameId: UInt64, in db: Database) throws {
        try db.execute(sql: """
            CREATE TABLE IF NOT EXISTS wax_lex_coverage (
                key TEXT PRIMARY KEY NOT NULL,
                value INTEGER NOT NULL
            )
            """)
        try db.execute(
            sql: """
                INSERT INTO wax_lex_coverage(key, value) VALUES (?, ?)
                ON CONFLICT(key) DO UPDATE SET value = excluded.value
                """,
            arguments: [key, try FTS5SearchEngine.toInt64(coveredBelowFrameId)]
        )
    }
}

extension FTS5SearchEngine {
    /// The text a frame should be indexed under, or `nil` when it is never text-indexed.
    ///
    /// Mirrors the memory write path: live document and chunk frames index their `searchText`.
    /// System frames (enrichment keywords, surrogates, markers) carry text but are not indexed.
    package static func indexableText(of frame: FrameMeta) -> String? {
        guard frame.status == .active, frame.supersededBy == nil else { return nil }
        guard frame.role == .document || frame.role == .chunk else { return nil }
        let text = frame.searchText?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return text.isEmpty ? nil : text
    }

    /// Indexes durable frames at or above the coverage watermark that have no postings.
    ///
    /// Idempotent: frames that already have postings are left as they are. Bounded: only
    /// frames at or above the watermark are examined. Returns the number of frames indexed.
    @discardableResult
    package func catchUpUnindexedFrames(_ metas: [FrameMeta]) async throws -> Int {
        // Without a recorded watermark, have the next commit record one even if nothing is
        // missing, so the full scan below runs once.
        if !coverageRecorded, !metas.isEmpty {
            dirty = true
        }
        let floor = coveredBelowFrameId
        var candidates: [(frameId: Int64, text: String)] = []
        for meta in metas where meta.id >= floor {
            guard let text = Self.indexableText(of: meta) else { continue }
            candidates.append((try Self.toInt64(meta.id), text))
        }
        guard !candidates.isEmpty else { return 0 }

        try await flushPendingOpsIfNeeded()
        let indexed = try await indexedFrameIds(atOrAbove: floor)
        var queued = 0
        for candidate in candidates where !indexed.contains(candidate.frameId) {
            if enqueueCatchUpUpsert(frameIdValue: candidate.frameId, text: candidate.text) {
                queued += 1
            }
        }
        if queued > 0 {
            try await flushPendingOpsIfNeeded()
        }
        return queued
    }

    /// Advances the watermark to the first indexable frame without postings (or past the last
    /// frame) and writes it into the blob. `metas` must be in ascending id order and hold
    /// every frame at or above the watermark, as `Wax.frameMetasIncludingPending()` and
    /// `Wax.frameMetasForTextStaging(atOrAbove:)` return them. Call after pending ops are flushed.
    func recordCoverage(of metas: [FrameMeta]) async throws {
        let floor = coveredBelowFrameId
        let indexed = try await indexedFrameIds(atOrAbove: floor)
        var covered = floor
        for meta in metas where meta.id >= floor {
            if Self.indexableText(of: meta) != nil, !indexed.contains(try Self.toInt64(meta.id)) {
                break
            }
            covered = meta.id + 1
        }
        let dbQueue = self.dbQueue
        let watermark = covered
        await beginWrite()
        defer { endWrite() }
        try await io.run {
            try dbQueue.write { db in
                try FTS5Coverage.write(coveredBelowFrameId: watermark, in: db)
            }
        }
        coveredBelowFrameId = covered
        coverageRecorded = true
    }

    /// The coverage watermark, to hand back to ``lowerCoverage(to:)`` when a commit that
    /// staged a higher one fails.
    package func coverageWatermark() -> UInt64 {
        coveredBelowFrameId
    }

    /// Moves the watermark back down to `frameId` after the commit of frames it vouched for
    /// failed; the next stage records the lowered value.
    package func lowerCoverage(to frameId: UInt64) {
        guard frameId < coveredBelowFrameId else { return }
        coveredBelowFrameId = frameId
        dirty = true
    }

    private func indexedFrameIds(atOrAbove floor: UInt64) async throws -> Set<Int64> {
        let dbQueue = self.dbQueue
        let floorValue = try Self.toInt64(floor)
        return try await io.run {
            try dbQueue.read { db in
                Set(try Int64.fetchAll(
                    db,
                    sql: "SELECT frame_id FROM frame_mapping WHERE frame_id >= ?",
                    arguments: [floorValue]
                ))
            }
        }
    }
}
