public enum CanonicalEncoding: UInt8, Equatable, Sendable {
    case plain = 0
    case lzfse = 1
    case lz4 = 2
    case deflate = 3
}

public enum FrameRole: UInt8, Equatable, Sendable {
    case document = 0
    case chunk = 1
    case blob = 2
    case system = 3
}

public enum FrameStatus: UInt8, Equatable, Sendable {
    case active = 0
    case deleted = 1
}

public enum SegmentCompression: UInt8, Equatable, Sendable {
    case none = 0
    case lzfse = 1
    case lz4 = 2
    case deflate = 3
}

public enum SegmentKind: UInt8, Equatable, Sendable {
    case lex = 0
    case vec = 1
    case time = 2
    case custom = 3
}

public enum VecSimilarity: UInt8, Equatable, Sendable {
    case cosine = 0
    case dot = 1
    case l2 = 2
}

