import Foundation

package struct WALFlags: OptionSet, Sendable, Equatable {
    package let rawValue: UInt32

    package init(rawValue: UInt32) {
        self.rawValue = rawValue
    }

    package static let isPadding = WALFlags(rawValue: 1 << 0)
}

package struct WALRecordHeader: Equatable, Sendable {
    package static let size: Int = 48

    package var sequence: UInt64
    package var length: UInt32
    package var flags: WALFlags
    package var checksum: Data

    package init(sequence: UInt64, length: UInt32, flags: WALFlags, checksum: Data) {
        self.sequence = sequence
        self.length = length
        self.flags = flags
        self.checksum = checksum
    }

    package var isSentinel: Bool {
        sequence == 0 && length == 0 && flags.rawValue == 0 && checksum.allSatisfy { $0 == 0 }
    }

    package func encode() throws -> Data {
        guard checksum.count == WALRecord.checksumSize else {
            throw WaxError.encodingError(reason: "checksum must be \(WALRecord.checksumSize) bytes (got \(checksum.count))")
        }

        var data = Data()
        data.reserveCapacity(Self.size)

        var seqLE = sequence.littleEndian
        var lenLE = length.littleEndian
        var flagsLE = flags.rawValue.littleEndian

        withUnsafeBytes(of: &seqLE) { data.append(contentsOf: $0) }
        withUnsafeBytes(of: &lenLE) { data.append(contentsOf: $0) }
        withUnsafeBytes(of: &flagsLE) { data.append(contentsOf: $0) }
        data.append(checksum)

        guard data.count == Self.size else {
            throw WaxError.encodingError(reason: "header size mismatch (got \(data.count), expected \(Self.size))")
        }
        return data
    }

    package static func decode(from data: Data, offset: UInt64) throws -> WALRecordHeader {
        guard data.count == Self.size else {
            throw WaxError.walCorruption(offset: offset, reason: "header must be \(Self.size) bytes (got \(data.count))")
        }

        func readUInt64(at offset: Int) -> UInt64 {
            var raw: UInt64 = 0
            _ = withUnsafeMutableBytes(of: &raw) { dest in
                data.copyBytes(to: dest, from: offset..<(offset + 8))
            }
            return UInt64(littleEndian: raw)
        }

        func readUInt32(at offset: Int) -> UInt32 {
            var raw: UInt32 = 0
            _ = withUnsafeMutableBytes(of: &raw) { dest in
                data.copyBytes(to: dest, from: offset..<(offset + 4))
            }
            return UInt32(littleEndian: raw)
        }

        let sequence = readUInt64(at: 0)
        let length = readUInt32(at: 8)
        let flags = WALFlags(rawValue: readUInt32(at: 12))
        let checksum = data.subdata(in: 16..<48)

        return WALRecordHeader(sequence: sequence, length: length, flags: flags, checksum: checksum)
    }
}

package enum WALRecord: Equatable, Sendable {
    package static let headerSize: Int = WALRecordHeader.size
    package static let checksumSize: Int = 32
    package static let paddingChecksum: Data = SHA256Checksum.digest(Data())

    case data(sequence: UInt64, flags: WALFlags, payload: Data)
    case padding(sequence: UInt64, skipBytes: UInt32)
    case sentinel

    package var sequence: UInt64? {
        switch self {
        case .data(let sequence, _, _):
            return sequence
        case .padding(let sequence, _):
            return sequence
        case .sentinel:
            return nil
        }
    }

    package func encode() throws -> Data {
        switch self {
        case .sentinel:
            return Data(repeating: 0, count: Self.headerSize)
        case .padding(let sequence, let skipBytes):
            let header = WALRecordHeader(
                sequence: sequence,
                length: skipBytes,
                flags: .isPadding,
                checksum: Self.paddingChecksum
            )
            return try header.encode()
        case .data(let sequence, let flags, let payload):
            guard payload.count <= Int(UInt32.max) else {
                throw WaxError.encodingError(reason: "payload too large (\(payload.count) bytes)")
            }
            let checksum = SHA256Checksum.digest(payload)
            let header = WALRecordHeader(
                sequence: sequence,
                length: UInt32(payload.count),
                flags: flags,
                checksum: checksum
            )
            var data = try header.encode()
            data.append(payload)
            return data
        }
    }

    package static func decodeRecord(from data: Data, walSize: UInt64, offset: UInt64 = 0) throws -> WALRecord {
        guard data.count >= Self.headerSize else {
            throw WaxError.walCorruption(offset: offset, reason: "record buffer shorter than header")
        }

        let header = try WALRecordHeader.decode(from: data.subdata(in: 0..<Self.headerSize), offset: offset)
        if header.isSentinel {
            return .sentinel
        }
        if header.sequence == 0 {
            throw WaxError.walCorruption(offset: offset, reason: "record sequence must be non-zero")
        }

        if header.flags.contains(.isPadding) {
            let maxSkip = walSize >= UInt64(Self.headerSize) ? walSize - UInt64(Self.headerSize) : 0
            guard UInt64(header.length) <= maxSkip else {
                throw WaxError.walCorruption(offset: offset, reason: "padding length exceeds WAL capacity")
            }
            guard header.checksum == Self.paddingChecksum else {
                throw WaxError.walCorruption(offset: offset, reason: "padding checksum mismatch")
            }
            return .padding(sequence: header.sequence, skipBytes: header.length)
        }

        guard header.length > 0 else {
            throw WaxError.walCorruption(offset: offset, reason: "record length must be > 0")
        }
        let maxPayload = walSize >= UInt64(Self.headerSize) ? walSize - UInt64(Self.headerSize) : 0
        guard UInt64(header.length) <= maxPayload else {
            throw WaxError.walCorruption(offset: offset, reason: "record length exceeds WAL capacity")
        }
        let payloadLength = Int(header.length)
        guard payloadLength <= Int.max - Self.headerSize else {
            throw WaxError.walCorruption(offset: offset, reason: "record length overflows buffer")
        }

        let expectedSize = Self.headerSize + payloadLength
        guard data.count == expectedSize else {
            throw WaxError.walCorruption(offset: offset, reason: "record size mismatch")
        }

        let payload = data.subdata(in: Self.headerSize..<expectedSize)
        let computed = SHA256Checksum.digest(payload)
        guard computed == header.checksum else {
            throw WaxError.walCorruption(offset: offset, reason: "payload checksum mismatch")
        }

        return .data(sequence: header.sequence, flags: header.flags, payload: payload)
    }
}
