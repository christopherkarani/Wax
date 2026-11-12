import Foundation

/// The vectors a sequence of runs holds, applied oldest first: a run's tombstones remove
/// the frames' vectors from older runs, and its rows add or replace vectors. A replaced
/// vector keeps its row; a removed one leaves a dead row until `compacted()`, and a frame
/// added again after a removal gets a new row at the end.
struct VecRunTable {
    let dimension: Int
    private(set) var frameIds: [UInt64] = []
    private(set) var vectors: [Float] = []
    private var live: [Bool] = []
    private var positions: [UInt64: Int] = [:]
    /// Frames removed by a tombstone and not added again since: what a merge of runs that
    /// are not the oldest must keep removing from the runs older than them.
    private(set) var tombstones: Set<UInt64> = []

    init(dimension: Int) {
        self.dimension = dimension
    }

    /// The table after applying `run` to an empty one, holding the run's arrays instead of
    /// copying them. A decoded run's rows are distinct (`VecRunCodec` checks); a run with a
    /// repeated row is applied row by row instead.
    init(adopting run: VecRun) {
        self.init(dimension: Int(run.dimension))
        var positions: [UInt64: Int] = [:]
        positions.reserveCapacity(run.frameIds.count)
        for (row, frameId) in run.frameIds.enumerated() {
            guard positions.updateValue(row, forKey: frameId) == nil else {
                apply(run)
                return
            }
        }
        for frameId in run.tombstones where positions[frameId] == nil {
            tombstones.insert(frameId)
        }
        self.positions = positions
        frameIds = run.frameIds
        vectors = run.vectors
        live = Array(repeating: true, count: run.frameIds.count)
    }

    /// Makes room for `rows` rows, so applying runs that add them does not regrow (and copy)
    /// the vectors and positions as they go.
    mutating func reserveCapacity(rows: Int) {
        frameIds.reserveCapacity(rows)
        vectors.reserveCapacity(rows * dimension)
        live.reserveCapacity(rows)
        positions.reserveCapacity(rows)
    }

    /// Rows held, dead ones included.
    var rowCount: Int { frameIds.count }

    var liveCount: Int { positions.count }

    mutating func apply(_ run: VecRun) {
        for frameId in run.tombstones {
            if let row = positions.removeValue(forKey: frameId) {
                live[row] = false
            }
            tombstones.insert(frameId)
        }
        run.vectors.withUnsafeBufferPointer { source in
            for (index, frameId) in run.frameIds.enumerated() {
                tombstones.remove(frameId)
                let start = index * dimension
                let row = UnsafeBufferPointer(rebasing: source[start..<(start + dimension)])
                if let existing = positions[frameId] {
                    vectors.withUnsafeMutableBufferPointer { target in
                        _ = UnsafeMutableBufferPointer(rebasing: target[(existing * dimension)...])
                            .initialize(from: row)
                    }
                } else {
                    positions[frameId] = frameIds.count
                    frameIds.append(frameId)
                    live.append(true)
                    vectors.append(contentsOf: row)
                }
            }
        }
    }

    /// The live rows in row order.
    func compacted() -> (frameIds: [UInt64], vectors: [Float]) {
        guard positions.count != frameIds.count else { return (frameIds, vectors) }
        var keptIds: [UInt64] = []
        var keptVectors: [Float] = []
        keptIds.reserveCapacity(positions.count)
        keptVectors.reserveCapacity(positions.count * dimension)
        for (row, frameId) in frameIds.enumerated() where live[row] {
            keptIds.append(frameId)
            keptVectors.append(contentsOf: vectors[(row * dimension)..<((row + 1) * dimension)])
        }
        return (keptIds, keptVectors)
    }
}

/// The frames with a vector after applying runs' keys, oldest run first.
struct VecRunKeys {
    private(set) var frameIds: Set<UInt64> = []

    mutating func apply(frameIds rows: [UInt64], tombstones: [UInt64]) {
        for frameId in tombstones {
            frameIds.remove(frameId)
        }
        frameIds.formUnion(rows)
    }
}
