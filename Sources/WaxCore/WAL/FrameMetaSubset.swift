import Foundation

package struct TagPair: Equatable, Sendable {
    package var key: String
    package var value: String

    package init(key: String, value: String) {
        self.key = key
        self.value = value
    }
}

package struct FrameMetaSubset: Equatable, Sendable {
    package var uri: String?
    package var title: String?
    package var kind: String?
    package var track: String?
    package var tags: [TagPair]
    package var labels: [String]
    package var contentDates: [String]
    package var role: FrameRole?
    package var parentId: UInt64?
    package var chunkIndex: UInt32?
    package var chunkCount: UInt32?
    package var chunkManifest: Data?
    package var status: FrameStatus?
    package var supersedes: UInt64?
    package var supersededBy: UInt64?
    package var searchText: String?
    package var metadata: Metadata?

    package init(
        uri: String? = nil,
        title: String? = nil,
        kind: String? = nil,
        track: String? = nil,
        tags: [TagPair] = [],
        labels: [String] = [],
        contentDates: [String] = [],
        role: FrameRole? = nil,
        parentId: UInt64? = nil,
        chunkIndex: UInt32? = nil,
        chunkCount: UInt32? = nil,
        chunkManifest: Data? = nil,
        status: FrameStatus? = nil,
        supersedes: UInt64? = nil,
        supersededBy: UInt64? = nil,
        searchText: String? = nil,
        metadata: Metadata? = nil
    ) {
        self.uri = uri
        self.title = title
        self.kind = kind
        self.track = track
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
        self.searchText = searchText
        self.metadata = metadata
    }
}

extension FrameMetaSubset: BinaryEncodable {
    package mutating func encode(to encoder: inout BinaryEncoder) throws {
        try encoder.encode(uri)
        try encoder.encode(title)
        try encoder.encode(kind)
        try encoder.encode(track)
        try encoder.encode(tags) { encoder, pair in
            try encoder.encode(pair.key)
            try encoder.encode(pair.value)
        }
        try encoder.encode(labels)
        try encoder.encode(contentDates)
        encoder.encode(role?.rawValue)
        encoder.encode(parentId)
        encoder.encode(chunkIndex)
        encoder.encode(chunkCount)
        try encoder.encode(chunkManifest) { encoder, value in
            try encoder.encodeBytes(value)
        }
        encoder.encode(status?.rawValue)
        encoder.encode(supersedes)
        encoder.encode(supersededBy)
        try encoder.encode(searchText)
        try encoder.encode(metadata) { encoder, value in
            var mutable = value
            try mutable.encode(to: &encoder)
        }
    }
}

extension FrameMetaSubset: BinaryDecodable {
    package static func decode(from decoder: inout BinaryDecoder) throws -> FrameMetaSubset {
        let uri = try decoder.decodeOptional(String.self)
        let title = try decoder.decodeOptional(String.self)
        let kind = try decoder.decodeOptional(String.self)
        let track = try decoder.decodeOptional(String.self)

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

        let roleRaw = try decoder.decodeOptional(UInt8.self)
        let role: FrameRole?
        if let roleRaw {
            guard let decoded = FrameRole(rawValue: roleRaw) else {
                throw WaxError.decodingError(reason: "invalid role \(roleRaw)")
            }
            role = decoded
        } else {
            role = nil
        }
        let parentId = try decoder.decodeOptional(UInt64.self)
        let chunkIndex = try decoder.decodeOptional(UInt32.self)
        let chunkCount = try decoder.decodeOptional(UInt32.self)

        let chunkManifest = try decodeOptionalBytes(from: &decoder, maxBytes: Constants.maxBlobBytes)

        let statusRaw = try decoder.decodeOptional(UInt8.self)
        let status: FrameStatus?
        if let statusRaw {
            guard let decoded = FrameStatus(rawValue: statusRaw) else {
                throw WaxError.decodingError(reason: "invalid status \(statusRaw)")
            }
            status = decoded
        } else {
            status = nil
        }
        let supersedes = try decoder.decodeOptional(UInt64.self)
        let supersededBy = try decoder.decodeOptional(UInt64.self)
        let searchText = try decoder.decodeOptional(String.self)

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

        return FrameMetaSubset(
            uri: uri,
            title: title,
            kind: kind,
            track: track,
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
            supersededBy: supersededBy,
            searchText: searchText,
            metadata: metadata
        )
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
