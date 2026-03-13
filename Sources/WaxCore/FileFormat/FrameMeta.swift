import Foundation

private enum FrameMetaValidation {
    static func validateInvariants(
        payloadLength: UInt64,
        canonicalEncoding: CanonicalEncoding,
        canonicalLength: UInt64?,
        storedChecksum: Data?
    ) throws {
        if canonicalEncoding != .plain, canonicalLength == nil {
            throw WaxError.invalidToc(reason: "missing canonical_length for compressed payload")
        }
        if payloadLength > 0, storedChecksum == nil {
            throw WaxError.invalidToc(reason: "missing stored_checksum when payload_length > 0")
        }
    }
}

package struct FrameMeta: Equatable, Sendable {
    package var id: UInt64
    package var timestamp: Int64
    package var anchorTs: Int64?
    package var kind: String?
    package var track: String?
    package var payloadOffset: UInt64
    package var payloadLength: UInt64
    package var checksum: Data
    package var uri: String?
    package var title: String?
    package var canonicalEncoding: CanonicalEncoding
    package var canonicalLength: UInt64?
    package var storedChecksum: Data?
    package var metadata: Metadata?
    package var searchText: String?
    package var tags: [TagPair]
    package var labels: [String]
    package var contentDates: [String]
    package var role: FrameRole
    package var parentId: UInt64?
    package var chunkIndex: UInt32?
    package var chunkCount: UInt32?
    package var chunkManifest: Data?
    package var status: FrameStatus
    package var supersedes: UInt64?
    package var supersededBy: UInt64?

    package init(
        id: UInt64,
        timestamp: Int64,
        anchorTs: Int64? = nil,
        kind: String? = nil,
        track: String? = nil,
        payloadOffset: UInt64,
        payloadLength: UInt64,
        checksum: Data,
        uri: String? = nil,
        title: String? = nil,
        canonicalEncoding: CanonicalEncoding,
        canonicalLength: UInt64? = nil,
        storedChecksum: Data? = nil,
        metadata: Metadata? = nil,
        searchText: String? = nil,
        tags: [TagPair] = [],
        labels: [String] = [],
        contentDates: [String] = [],
        role: FrameRole = .document,
        parentId: UInt64? = nil,
        chunkIndex: UInt32? = nil,
        chunkCount: UInt32? = nil,
        chunkManifest: Data? = nil,
        status: FrameStatus = .active,
        supersedes: UInt64? = nil,
        supersededBy: UInt64? = nil
    ) {
        self.id = id
        self.timestamp = timestamp
        self.anchorTs = anchorTs
        self.kind = kind
        self.track = track
        self.payloadOffset = payloadOffset
        self.payloadLength = payloadLength
        self.checksum = checksum
        self.uri = uri
        self.title = title
        self.canonicalEncoding = canonicalEncoding
        self.canonicalLength = canonicalLength
        self.storedChecksum = storedChecksum
        self.metadata = metadata
        self.searchText = searchText
        self.tags = tags
        self.labels = labels
        self.contentDates = contentDates
        self.role = role
        self.parentId = parentId
        self.chunkIndex = chunkIndex
        self.chunkCount = chunkCount
        self.chunkManifest = chunkManifest
        self.status = status
        self.supersedes = supersedes
        self.supersededBy = supersededBy
    }
}

extension FrameMeta: BinaryEncodable {
    package mutating func encode(to encoder: inout BinaryEncoder) throws {
        do {
            try FrameMetaValidation.validateInvariants(
                payloadLength: payloadLength,
                canonicalEncoding: canonicalEncoding,
                canonicalLength: canonicalLength,
                storedChecksum: storedChecksum
            )
        } catch let error as WaxError {
            throw WaxError.encodingError(reason: error.localizedDescription)
        }

        encoder.encode(id)
        encoder.encode(timestamp)
        encoder.encode(anchorTs)
        try encoder.encode(kind)
        try encoder.encode(track)
        encoder.encode(payloadOffset)
        encoder.encode(payloadLength)
        try encoder.encodeFixedChecksum(checksum, field: "checksum")
        try encoder.encode(uri)
        try encoder.encode(title)
        encoder.encode(canonicalEncoding.rawValue)
        encoder.encode(canonicalLength)
        try encoder.encodeOptionalFixedChecksum(storedChecksum, field: "stored_checksum")
        try encoder.encode(metadata) { encoder, value in
            var mutable = value
            try mutable.encode(to: &encoder)
        }
        try encoder.encode(searchText)
        try encoder.encode(tags) { encoder, pair in
            try encoder.encode(pair.key)
            try encoder.encode(pair.value)
        }
        try encoder.encode(labels)
        try encoder.encode(contentDates)
        encoder.encode(role.rawValue)
        encoder.encode(parentId)
        encoder.encode(chunkIndex)
        encoder.encode(chunkCount)
        try encoder.encode(chunkManifest) { encoder, value in
            try encoder.encodeBytes(value)
        }
        encoder.encode(status.rawValue)
        encoder.encode(supersedes)
        encoder.encode(supersededBy)
    }
}

extension FrameMeta: BinaryDecodable {
    package static func decode(from decoder: inout BinaryDecoder) throws -> FrameMeta {
        let id = try decoder.decode(UInt64.self)
        let timestamp = try decoder.decode(Int64.self)
        let anchorTs = try decoder.decodeOptional(Int64.self)
        let kind = try decoder.decodeOptional(String.self)
        let track = try decoder.decodeOptional(String.self)
        let payloadOffset = try decoder.decode(UInt64.self)
        let payloadLength = try decoder.decode(UInt64.self)
        let checksum = try decoder.decodeFixedBytes(count: 32)
        let uri = try decoder.decodeOptional(String.self)
        let title = try decoder.decodeOptional(String.self)
        let canonicalEncodingRaw = try decoder.decode(UInt8.self)
        guard let canonicalEncoding = CanonicalEncoding(rawValue: canonicalEncodingRaw) else {
            throw WaxError.invalidToc(reason: "invalid canonical_encoding \(canonicalEncodingRaw)")
        }
        let canonicalLength = try decoder.decodeOptional(UInt64.self)
        let storedChecksum = try decodeOptionalFixedChecksum(from: &decoder, field: "stored_checksum")

        let metadataTag = try decoder.decode(UInt8.self)
        let metadata: Metadata?
        switch metadataTag {
        case 0:
            metadata = nil
        case 1:
            metadata = try Metadata.decode(from: &decoder)
        default:
            throw WaxError.decodingError(reason: "invalid optional tag \(metadataTag) for metadata")
        }

        let searchText = try decoder.decodeOptional(String.self)

        let tagCount = Int(try decoder.decode(UInt32.self))
        guard tagCount <= Constants.maxArrayCount else {
            throw WaxError.decodingError(reason: "tags count \(tagCount) exceeds limit \(Constants.maxArrayCount)")
        }
        var tags: [TagPair] = []
        tags.reserveCapacity(tagCount)
        for _ in 0..<tagCount {
            let key = try decoder.decode(String.self)
            let value = try decoder.decode(String.self)
            tags.append(TagPair(key: key, value: value))
        }

        let labels = try decoder.decodeArray(String.self)
        let contentDates = try decoder.decodeArray(String.self)
        let roleRaw = try decoder.decode(UInt8.self)
        guard let role = FrameRole(rawValue: roleRaw) else {
            throw WaxError.invalidToc(reason: "invalid role \(roleRaw)")
        }
        let parentId = try decoder.decodeOptional(UInt64.self)
        let chunkIndex = try decoder.decodeOptional(UInt32.self)
        let chunkCount = try decoder.decodeOptional(UInt32.self)
        let chunkManifest = try decodeOptionalBytes(from: &decoder, maxBytes: Constants.maxBlobBytes)
        let statusRaw = try decoder.decode(UInt8.self)
        guard let status = FrameStatus(rawValue: statusRaw) else {
            throw WaxError.invalidToc(reason: "invalid status \(statusRaw)")
        }
        let supersedes = try decoder.decodeOptional(UInt64.self)
        let supersededBy = try decoder.decodeOptional(UInt64.self)

        try FrameMetaValidation.validateInvariants(
            payloadLength: payloadLength,
            canonicalEncoding: canonicalEncoding,
            canonicalLength: canonicalLength,
            storedChecksum: storedChecksum
        )

        return FrameMeta(
            id: id,
            timestamp: timestamp,
            anchorTs: anchorTs,
            kind: kind,
            track: track,
            payloadOffset: payloadOffset,
            payloadLength: payloadLength,
            checksum: checksum,
            uri: uri,
            title: title,
            canonicalEncoding: canonicalEncoding,
            canonicalLength: canonicalLength,
            storedChecksum: storedChecksum,
            metadata: metadata,
            searchText: searchText,
            tags: tags,
            labels: labels,
            contentDates: contentDates,
            role: role,
            parentId: parentId,
            chunkIndex: chunkIndex,
            chunkCount: chunkCount,
            chunkManifest: chunkManifest,
            status: status,
            supersedes: supersedes,
            supersededBy: supersededBy
        )
    }
}

extension FrameMeta {
    package static func fromPut(_ put: PutFrame) throws -> FrameMeta {
        guard put.canonicalChecksum.count == 32 else {
            throw WaxError.encodingError(reason: "canonical_checksum must be 32 bytes")
        }
        guard put.storedChecksum.count == 32 else {
            throw WaxError.encodingError(reason: "stored_checksum must be 32 bytes")
        }

        let options = put.options
        let canonicalLength: UInt64? = put.canonicalEncoding == .plain ? nil : put.canonicalLength
        let storedChecksum: Data? = put.payloadLength > 0 ? put.storedChecksum : nil

        return FrameMeta(
            id: put.frameId,
            timestamp: put.timestampMs,
            anchorTs: nil,
            kind: options.kind,
            track: options.track,
            payloadOffset: put.payloadOffset,
            payloadLength: put.payloadLength,
            checksum: put.canonicalChecksum,
            uri: options.uri,
            title: options.title,
            canonicalEncoding: put.canonicalEncoding,
            canonicalLength: canonicalLength,
            storedChecksum: storedChecksum,
            metadata: options.metadata,
            searchText: options.searchText,
            tags: options.tags,
            labels: options.labels,
            contentDates: options.contentDates,
            role: options.role ?? .document,
            parentId: options.parentId,
            chunkIndex: options.chunkIndex,
            chunkCount: options.chunkCount,
            chunkManifest: options.chunkManifest,
            status: options.status ?? .active,
            supersedes: options.supersedes,
            supersededBy: options.supersededBy
        )
    }
}

private extension BinaryEncoder {
    mutating func encodeFixedChecksum(_ value: Data, field: String) throws {
        guard value.count == 32 else {
            throw WaxError.encodingError(reason: "\(field) must be 32 bytes (got \(value.count))")
        }
        encodeFixedBytes(value)
    }

    mutating func encodeOptionalFixedChecksum(_ value: Data?, field: String) throws {
        if let value {
            encode(UInt8(1))
            try encodeFixedChecksum(value, field: field)
        } else {
            encode(UInt8(0))
        }
    }
}

private func decodeOptionalFixedChecksum(from decoder: inout BinaryDecoder, field: String) throws -> Data? {
    let tag = try decoder.decode(UInt8.self)
    switch tag {
    case 0:
        return nil
    case 1:
        let value = try decoder.decodeFixedBytes(count: 32)
        return value
    default:
        throw WaxError.decodingError(reason: "invalid optional tag \(tag) for \(field)")
    }
}

private func decodeOptionalBytes(from decoder: inout BinaryDecoder, maxBytes: Int) throws -> Data? {
    let tag = try decoder.decode(UInt8.self)
    switch tag {
    case 0:
        return nil
    case 1:
        return try decoder.decodeBytes(maxBytes: maxBytes)
    default:
        throw WaxError.decodingError(reason: "invalid optional tag \(tag)")
    }
}
