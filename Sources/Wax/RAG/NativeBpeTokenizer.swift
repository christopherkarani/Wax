import Foundation
import WaxCore

package final class NativeBpeTokenizer: @unchecked Sendable {
    package enum Encoding: String, Sendable {
        case cl100kBase = "cl100k_base"
    }

    static let cl100kBasePattern = #"(?i:'s|'t|'re|'ve|'m|'ll|'d)|[^\r\n\p{L}\p{N}]?\p{L}+|\p{N}{1,3}| ?[^\s\p{L}\p{N}]+[\r\n]*|\s*[\r\n]+|\s+(?!\S)|\s+"#

    private static let cl100kBaseRegex: NSRegularExpression = {
        do {
            return try NSRegularExpression(pattern: cl100kBasePattern, options: [])
        } catch {
            preconditionFailure("Invalid cl100k_base regex: \(error)")
        }
    }()

    private final class LockedCache<Key: Hashable & Sendable, Value: Sendable>: @unchecked Sendable {
        private let lock = NSLock()
        private var state: [Key: Value] = [:]

        func get(_ key: Key) -> Value? {
            lock.lock()
            defer { lock.unlock() }
            return state[key]
        }

        func set(_ key: Key, _ value: Value) {
            lock.lock()
            defer { lock.unlock() }
            state[key] = value
        }
    }

    private let encoder: [Data: UInt32]
    /// `encoder` restricted to pieces of at most `shortPieceMaxBytes` bytes, keyed by
    /// `shortKey`: most pieces are short single tokens, and an integer key hashes far
    /// faster than `Data`.
    private let shortEncoder: [UInt64: UInt32]
    private static let shortPieceMaxBytes = 7
    private let decoder: [UInt32: Data]
    private let regex: NSRegularExpression
    private let bpeCache = LockedCache<Data, [UInt32]>()

    package init(encoding: Encoding = .cl100kBase) throws {
        let (encoder, decoder) = try Self.loadEncoding(encoding)
        self.encoder = encoder
        self.decoder = decoder
        var shortEncoder: [UInt64: UInt32] = [:]
        for (bytes, rank) in encoder where bytes.count <= Self.shortPieceMaxBytes {
            shortEncoder[Self.shortKey(bytes)] = rank
        }
        self.shortEncoder = shortEncoder
        self.regex = Self.cl100kBaseRegex
    }

    package static func preload(encoding: Encoding = .cl100kBase) throws -> NativeBpeTokenizer {
        try NativeBpeTokenizer(encoding: encoding)
    }

    package func encode(_ text: String) -> [UInt32] {
        guard !text.isEmpty else { return [] }
        var tokens: [UInt32] = []
        tokens.reserveCapacity(text.utf8.count)

        // Text splits without ICU, which was about half of a short save's CPU time, unless
        // it holds a scalar ICU may class differently.
        let scanned = text.utf8.withContiguousStorageIfAvailable { bytes -> Bool in
            guard let ranges = Cl100kPreTokenizer.pieceRanges(bytes) else { return false }
            for range in ranges {
                appendTokens(forPiece: UnsafeBufferPointer(rebasing: bytes[range]), to: &tokens)
            }
            return true
        } ?? false
        if scanned { return tokens }

        let matches = regex.matches(in: text, range: NSRange(text.startIndex..., in: text))
        for match in matches {
            guard let range = Range(match.range, in: text) else { continue }
            let piece = Array(text[range].utf8)
            piece.withUnsafeBufferPointer { appendTokens(forPiece: $0, to: &tokens) }
        }

        return tokens
    }

    /// The piece's bytes in the low bytes and its length in the top byte, so pieces of
    /// different lengths never collide. Only for pieces of at most `shortPieceMaxBytes`.
    private static func shortKey<Bytes: Collection<UInt8>>(_ bytes: Bytes) -> UInt64 {
        var key = UInt64(bytes.count) << 56
        for (index, byte) in bytes.enumerated() {
            key |= UInt64(byte) << (8 * UInt64(index))
        }
        return key
    }

    private func appendTokens(forPiece bytes: UnsafeBufferPointer<UInt8>, to tokens: inout [UInt32]) {
        if bytes.isEmpty { return }
        if bytes.count <= Self.shortPieceMaxBytes, let token = shortEncoder[Self.shortKey(bytes)] {
            tokens.append(token)
            return
        }

        let data = Data(buffer: bytes)
        // Most pieces are one token. The vocabulary is immutable, so looking it up first
        // takes no lock: chunkers encoding in parallel queued on the cache lock for every
        // piece, and ran slower than one chunker alone.
        if let token = encoder[data] {
            tokens.append(token)
            return
        }

        if let cached = bpeCache.get(data) {
            tokens.append(contentsOf: cached)
            return
        }

        let encoded = bpeEncode(Array(bytes))
        bpeCache.set(data, encoded)
        tokens.append(contentsOf: encoded)
    }

    package func decode(_ tokens: [UInt32]) -> String {
        guard !tokens.isEmpty else { return "" }
        var data = Data()
        data.reserveCapacity(tokens.count * 2)
        for token in tokens {
            if let bytes = decoder[token] {
                data.append(bytes)
            }
        }
        // Byte-level BPE can split a multi-byte scalar across tokens. A token
        // prefix (truncation) may end mid-scalar; drop that partial tail rather
        // than decoding it to U+FFFD.
        data.removeLast(Self.incompleteUTF8SuffixLength(data))
        return String(decoding: data, as: UTF8.self)
    }

    /// `true` when `token`'s bytes start with a UTF-8 continuation byte, so a cut just before
    /// it would split a multi-byte scalar.
    package func beginsInsideScalar(_ token: UInt32) -> Bool {
        guard let first = decoder[token]?.first else { return false }
        return first & 0b1100_0000 == 0b1000_0000
    }

    /// Length (0...3) of a trailing UTF-8 sequence whose lead byte promises
    /// more continuation bytes than are present.
    static func incompleteUTF8SuffixLength(_ data: Data) -> Int {
        var continuationCount = 0
        var index = data.endIndex
        while index > data.startIndex, continuationCount < 4 {
            index = data.index(before: index)
            let byte = data[index]
            if byte & 0b1100_0000 == 0b1000_0000 {
                continuationCount += 1
                continue
            }
            let expected: Int
            switch byte {
            case 0b1100_0000...0b1101_1111: expected = 1
            case 0b1110_0000...0b1110_1111: expected = 2
            case 0b1111_0000...0b1111_0111: expected = 3
            default: return 0
            }
            return continuationCount < expected ? continuationCount + 1 : 0
        }
        return 0
    }

    private func bpeEncode(_ bytes: [UInt8]) -> [UInt32] {
        var parts = bytes.map { Data([$0]) }
        guard parts.count > 1 else {
            if let token = encoder[parts[0]] {
                return [token]
            }
            return []
        }

        var heap = BpeMergeHeap()
        
        for index in 0..<(parts.count - 1) {
            let merged = Self.merge(parts[index], parts[index + 1])
            if let rank = encoder[merged] {
                heap.insert(BpeMergeEntry(rank: rank, index: index))
            }
        }
        
        var removed = [Bool](repeating: false, count: parts.count)
        
        while let best = heap.popMin() {
            let idx = best.index
            
            if removed[idx] { continue }
            
            var nextIdx = idx + 1
            while nextIdx < parts.count && removed[nextIdx] { nextIdx += 1 }
            if nextIdx >= parts.count { continue }
            
            let merged = Self.merge(parts[idx], parts[nextIdx])
            guard let currentRank = encoder[merged], currentRank == best.rank else {
                continue
            }
            
            parts[idx] = merged
            removed[nextIdx] = true
            
            var prevIdx = idx - 1
            while prevIdx >= 0 && removed[prevIdx] { prevIdx -= 1 }
            if prevIdx >= 0 {
                let prevMerged = Self.merge(parts[prevIdx], parts[idx])
                if let rank = encoder[prevMerged] {
                    heap.insert(BpeMergeEntry(rank: rank, index: prevIdx))
                }
            }
            
            var nextNextIdx = nextIdx + 1
            while nextNextIdx < parts.count && removed[nextNextIdx] { nextNextIdx += 1 }
            if nextNextIdx < parts.count {
                let nextMerged = Self.merge(parts[idx], parts[nextNextIdx])
                if let rank = encoder[nextMerged] {
                    heap.insert(BpeMergeEntry(rank: rank, index: idx))
                }
            }
        }

        var tokens: [UInt32] = []
        tokens.reserveCapacity(parts.count)
        for (index, part) in parts.enumerated() {
            if removed[index] { continue }
            if let token = encoder[part] {
                tokens.append(token)
            } else {
                for byte in part {
                    let byteData = Data([byte])
                    if let token = encoder[byteData] {
                        tokens.append(token)
                    }
                }
            }
        }
        return tokens
    }

    private struct BpeMergeEntry: Comparable {
        let rank: UInt32
        let index: Int
        
        static func < (lhs: BpeMergeEntry, rhs: BpeMergeEntry) -> Bool {
            if lhs.rank != rhs.rank { return lhs.rank < rhs.rank }
            return lhs.index < rhs.index
        }
    }
    
    private struct BpeMergeHeap {
        private var elements: [BpeMergeEntry] = []
        
        var isEmpty: Bool { elements.isEmpty }
        
        mutating func insert(_ entry: BpeMergeEntry) {
            elements.append(entry)
            siftUp(elements.count - 1)
        }
        
        mutating func popMin() -> BpeMergeEntry? {
            guard !elements.isEmpty else { return nil }
            if elements.count == 1 { return elements.removeLast() }
            let min = elements[0]
            elements[0] = elements.removeLast()
            siftDown(0)
            return min
        }
        
        private mutating func siftUp(_ index: Int) {
            var child = index
            var parent = (child - 1) / 2
            while child > 0 && elements[child] < elements[parent] {
                elements.swapAt(child, parent)
                child = parent
                parent = (child - 1) / 2
            }
        }
        
        private mutating func siftDown(_ index: Int) {
            var parent = index
            while true {
                let left = 2 * parent + 1
                let right = 2 * parent + 2
                var smallest = parent
                if left < elements.count && elements[left] < elements[smallest] {
                    smallest = left
                }
                if right < elements.count && elements[right] < elements[smallest] {
                    smallest = right
                }
                if smallest == parent { break }
                elements.swapAt(parent, smallest)
                parent = smallest
            }
        }
    }

    private static func merge(_ left: Data, _ right: Data) -> Data {
        var data = Data()
        data.reserveCapacity(left.count + right.count)
        data.append(left)
        data.append(right)
        return data
    }

    private static let resourceBundle: Bundle = WaxBundleResolver.resolveModule(
        named: "Wax_Wax.bundle",
        moduleFallback: .module
    )

    private static func loadEncoding(_ encoding: Encoding) throws -> ([Data: UInt32], [UInt32: Data]) {
        let url =
            resourceBundle.url(forResource: encoding.rawValue, withExtension: "tiktoken")
            ?? resourceBundle.url(forResource: encoding.rawValue, withExtension: "tiktoken", subdirectory: "RAG/Resources")

        guard let url else {
            throw NativeBpeError.missingResource(encoding: encoding.rawValue)
        }

        let content = try String(contentsOf: url, encoding: .utf8)
        var encoder: [Data: UInt32] = [:]
        encoder.reserveCapacity(100_000)
        var decoder: [UInt32: Data] = [:]
        decoder.reserveCapacity(100_000)

        for line in content.split(whereSeparator: \.isNewline) {
            let parts = line.split(separator: " ")
            guard parts.count == 2, let rank = UInt32(parts[1]) else { continue }
            let base64 = String(parts[0])
            guard let data = Data(base64Encoded: base64) else { continue }
            encoder[data] = rank
            decoder[rank] = data
        }

        return (encoder, decoder)
    }

    /// Returns the directory that contains Wax’s bundled `.tiktoken` encoding files.
    static func bundledEncodingDirectoryURL() -> URL? {
        let url =
            resourceBundle.url(forResource: Encoding.cl100kBase.rawValue, withExtension: "tiktoken")
            ?? resourceBundle.url(forResource: Encoding.cl100kBase.rawValue, withExtension: "tiktoken", subdirectory: "RAG/Resources")
        return url?.deletingLastPathComponent()
    }
}

package enum NativeBpeError: Error, Sendable {
    case missingResource(encoding: String)
}
