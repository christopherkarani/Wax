import Foundation

public final class NativeBpeTokenizer: @unchecked Sendable {
    public enum Encoding: String, Sendable {
        case cl100kBase = "cl100k_base"
    }

    private static let cl100kBasePattern = #"(?i:'s|'t|'re|'ve|'m|'ll|'d)|[^\r\n\p{L}\p{N}]?\p{L}+|\p{N}{1,3}| ?[^\s\p{L}\p{N}]+[\r\n]*|\s*[\r\n]+|\s+(?!\S)|\s+"#

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
    private let decoder: [UInt32: Data]
    private let regex: NSRegularExpression
    private let bpeCache = LockedCache<Data, [UInt32]>()

    public init(encoding: Encoding = .cl100kBase) throws {
        let (encoder, decoder) = try Self.loadEncoding(encoding)
        self.encoder = encoder
        self.decoder = decoder
        self.regex = Self.cl100kBaseRegex
    }

    public static func preload(encoding: Encoding = .cl100kBase) throws -> NativeBpeTokenizer {
        try NativeBpeTokenizer(encoding: encoding)
    }

    public func encode(_ text: String) -> [UInt32] {
        guard !text.isEmpty else { return [] }
        let matches = regex.matches(in: text, range: NSRange(text.startIndex..., in: text))
        var tokens: [UInt32] = []
        tokens.reserveCapacity(text.utf8.count)

        for match in matches {
            guard let range = Range(match.range, in: text) else { continue }
            let piece = text[range]
            let bytes = Array(piece.utf8)
            if bytes.isEmpty { continue }

            let data = Data(bytes)
            if let cached = bpeCache.get(data) {
                tokens.append(contentsOf: cached)
                continue
            }

            if let token = encoder[data] {
                let encoded = [token]
                bpeCache.set(data, encoded)
                tokens.append(token)
                continue
            }

            let encoded = bpeEncode(bytes)
            bpeCache.set(data, encoded)
            tokens.append(contentsOf: encoded)
        }

        return tokens
    }

    public func decode(_ tokens: [UInt32]) -> String {
        guard !tokens.isEmpty else { return "" }
        var data = Data()
        data.reserveCapacity(tokens.count * 2)
        for token in tokens {
            if let bytes = decoder[token] {
                data.append(bytes)
            }
        }
        return String(decoding: data, as: UTF8.self)
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

    private static func loadEncoding(_ encoding: Encoding) throws -> ([Data: UInt32], [UInt32: Data]) {
        let url =
            Bundle.module.url(forResource: encoding.rawValue, withExtension: "tiktoken")
            ?? Bundle.module.url(forResource: encoding.rawValue, withExtension: "tiktoken", subdirectory: "RAG/Resources")

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
            Bundle.module.url(forResource: Encoding.cl100kBase.rawValue, withExtension: "tiktoken")
            ?? Bundle.module.url(forResource: Encoding.cl100kBase.rawValue, withExtension: "tiktoken", subdirectory: "RAG/Resources")
        return url?.deletingLastPathComponent()
    }
}

public enum NativeBpeError: Error, Sendable {
    case missingResource(encoding: String)
}
