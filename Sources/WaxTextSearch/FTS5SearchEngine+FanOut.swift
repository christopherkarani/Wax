import Foundation
@preconcurrency import GRDB
import WaxCore

// Fan-out MATCH evaluation.
//
// SQLite computes bm25() and snippet() for every row a MATCH selects before ORDER BY ...
// LIMIT keeps the best few. An OR query over common words selects most of a large corpus
// (tens of thousands of rows at 100k passages), so one statement on the single serial
// connection costs tens of milliseconds and every other read of the index waits for it.
//
// Large indexes therefore split the rowid space into ranges and score each range on its
// own read-only connection at the same time. bm25() takes its IDF and row count from the
// whole table, not from the rows a statement visits, so a row scores the same in any
// range. Each range returns its best `limit` rows in the single statement's order, the
// global best `limit` are among them, and merging in that order returns the rows the
// single statement would have returned.

extension FTS5SearchEngine {
    /// When one MATCH is split across read-only connections.
    package struct SearchFanOut: Sendable, Equatable {
        /// Indexed documents each partition should hold at least.
        package var minDocsPerPartition: Int
        /// Read-only connections, and so the most partitions one search uses.
        package var maxPartitions: Int

        package init(minDocsPerPartition: Int, maxPartitions: Int) {
            self.minDocsPerPartition = max(1, minDocsPerPartition)
            self.maxPartitions = max(1, maxPartitions)
        }

        /// One statement on the serial connection, as in-memory indexes always use.
        package static let disabled = SearchFanOut(minDocsPerPartition: .max, maxPartitions: 1)

        /// Splits from 50k documents, up to four ways but never past half the cores.
        package static let `default` = SearchFanOut(
            minDocsPerPartition: 25_000,
            maxPartitions: min(4, ProcessInfo.processInfo.activeProcessorCount / 2)
        )

        func partitionCount(docCount: UInt64) -> Int {
            guard maxPartitions > 1 else { return 1 }
            let byDocs = docCount / UInt64(minDocsPerPartition)
            return Int(min(UInt64(maxPartitions), max(1, byDocs)))
        }
    }

    /// One MATCH result row before score normalization.
    struct MatchRow: Sendable {
        let frameId: Int64?
        let rank: Double
        let snippet: String?
    }

    static let busyTimeoutSeconds: TimeInterval = 10

    /// The MATCH statement, optionally restricted to an inclusive FTS rowid range.
    static func matchRows(
        _ db: Database,
        matchQuery: String,
        limit: Int,
        rowidRange: ClosedRange<Int64>?
    ) throws -> [MatchRow] {
        let rangeClause = rowidRange == nil ? "" : "AND frames_fts.rowid BETWEEN ? AND ?"
        let sql = """
            SELECT m.frame_id AS frame_id,
                   bm25(frames_fts) AS rank,
                   snippet(frames_fts, 0, '\(snippetOpenMarker)', '\(snippetCloseMarker)', '...', 10) AS snippet
            FROM frames_fts
            JOIN frame_mapping m ON m.rowid_ref = frames_fts.rowid
            WHERE frames_fts MATCH ? \(rangeClause)
            ORDER BY rank ASC, m.frame_id ASC
            LIMIT ?
            """
        var arguments: StatementArguments = [matchQuery]
        if let rowidRange {
            arguments += [rowidRange.lowerBound, rowidRange.upperBound]
        }
        arguments += [limit]
        return try Row.fetchAll(db, sql: sql, arguments: arguments).map { row in
            MatchRow(frameId: row["frame_id"], rank: row["rank"] ?? 0, snippet: row["snippet"])
        }
    }

    /// Inclusive rowid ranges that cover every Int64 and split `[minRowid, maxRowid]` evenly.
    static func rowidRanges(minRowid: Int64, maxRowid: Int64, partitions: Int) -> [ClosedRange<Int64>] {
        let (span, overflow) = maxRowid.subtractingReportingOverflow(minRowid)
        guard partitions > 1, !overflow, span > 0 else { return [Int64.min...Int64.max] }
        let step = span / Int64(partitions) + 1
        var ranges: [ClosedRange<Int64>] = []
        var lower = Int64.min
        var bound = minRowid
        for _ in 1..<partitions {
            // bound <= minRowid + span, so it never overflows.
            bound += step
            guard bound <= maxRowid else { break }
            ranges.append(lower...(bound - 1))
            lower = bound
        }
        ranges.append(lower...Int64.max)
        return ranges
    }

    func fanOutMatchRows(matchQuery: String, limit: Int, partitions: Int) async throws -> [MatchRow] {
        // Opening a reader reads the file, so the first search opens them inside the gate too:
        // an open racing a write on the writer connection failed it with a disk I/O error.
        await beginFanOutRead()
        defer { endFanOutRead() }
        let readers = try await fanOutReaders()
        if let duringFanOutReadForTesting {
            await duringFanOutReadForTesting()
        }

        let first = readers[0]
        let bounds = try await io.run {
            try first.read { db -> (Int64, Int64)? in
                let row = try Row.fetchOne(db, sql: """
                    SELECT (SELECT MIN(rowid_ref) FROM frame_mapping) AS lo,
                           (SELECT MAX(rowid_ref) FROM frame_mapping) AS hi
                    """)
                guard let lo: Int64 = row?["lo"], let hi: Int64 = row?["hi"] else { return nil }
                return (lo, hi)
            }
        }
        guard let bounds else { return [] }
        let ranges = Self.rowidRanges(minRowid: bounds.0, maxRowid: bounds.1, partitions: partitions)

        let io = self.io
        let merged = try await withThrowingTaskGroup(of: [MatchRow].self) { group in
            for (index, range) in ranges.enumerated() {
                let reader = readers[index % readers.count]
                group.addTask {
                    try await io.run {
                        try reader.read { db in
                            try Self.matchRows(db, matchQuery: matchQuery, limit: limit, rowidRange: range)
                        }
                    }
                }
            }
            var rows: [MatchRow] = []
            for try await partition in group {
                rows.append(contentsOf: partition)
            }
            return rows
        }
        // The single statement's ORDER BY rank ASC, frame_id ASC (SQLite sorts NULL first).
        return Array(merged.sorted { lhs, rhs in
            if lhs.rank != rhs.rank { return lhs.rank < rhs.rank }
            return (lhs.frameId ?? .min) < (rhs.frameId ?? .min)
        }.prefix(limit))
    }

    /// Opens the read-only connections once; a failed open is retried by the next search.
    private func fanOutReaders() async throws -> [DatabaseQueue] {
        if let readerPool {
            return try await readerPool.value
        }
        guard let databaseURL else {
            throw WaxError.io("fan-out search needs an on-disk index")
        }
        let count = searchFanOut.maxPartitions
        let io = self.io
        let task = Task {
            try await io.run {
                try (0..<count).map { _ in
                    try DatabaseQueue(path: databaseURL.path, configuration: Self.readerConfiguration())
                }
            }
        }
        readerPool = task
        do {
            return try await task.value
        } catch {
            readerPool = nil
            throw error
        }
    }

    private static func readerConfiguration() -> Configuration {
        var config = Configuration()
        config.readonly = true
        // A commit on the writer connection holds the file lock for its duration.
        config.busyMode = .timeout(busyTimeoutSeconds)
        config.prepareDatabase { db in
            try db.execute(sql: "PRAGMA temp_store=MEMORY")
        }
        return config
    }

    // MARK: - Snapshot gate

    // Partitions run in separate read transactions, so a commit that landed between two of
    // them would mix snapshots (an upserted frame could appear under its old and new rowid),
    // and a rollback-journal commit racing the readers' shared locks can fail outright.
    // Every write on the writer connection waits for fan-out reads to finish, and fan-out
    // reads wait for a running or queued write. Only this actor writes, so the gate covers every writer.

    func beginWrite() async {
        writersWaiting += 1
        while writeInProgress || fanOutReadsInFlight > 0 {
            await withCheckedContinuation { writeGateWaiters.append($0) }
        }
        writersWaiting -= 1
        writeInProgress = true
    }

    func endWrite() {
        writeInProgress = false
        resumeWriteGateWaiters()
    }

    private func beginFanOutRead() async {
        // Queued writers go first, so back-to-back searches cannot hold off a commit. A
        // writer only waits for reads already in flight, which never wait, so this cannot
        // deadlock.
        while writeInProgress || writersWaiting > 0 {
            fanOutReadersWaiting += 1
            await withCheckedContinuation { writeGateWaiters.append($0) }
            fanOutReadersWaiting -= 1
        }
        fanOutReadsInFlight += 1
    }

    private func endFanOutRead() {
        fanOutReadsInFlight -= 1
        if fanOutReadsInFlight == 0 {
            resumeWriteGateWaiters()
        }
    }

    private func resumeWriteGateWaiters() {
        let waiters = writeGateWaiters
        writeGateWaiters.removeAll()
        for waiter in waiters {
            waiter.resume()
        }
    }
}
