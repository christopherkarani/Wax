/// Supported compression algorithms for frame payload bytes (v1).
public enum CompressionKind: Sendable, Equatable {
    case none
    case lzfse
    case lz4
    case deflate
}

extension CompressionKind {
    init(canonicalEncoding: CanonicalEncoding) {
        switch canonicalEncoding {
        case .plain:
            self = .none
        case .lzfse:
            self = .lzfse
        case .lz4:
            self = .lz4
        case .deflate:
            self = .deflate
        }
    }

    var canonicalEncoding: CanonicalEncoding {
        switch self {
        case .none:
            return .plain
        case .lzfse:
            return .lzfse
        case .lz4:
            return .lz4
        case .deflate:
            return .deflate
        }
    }
}
