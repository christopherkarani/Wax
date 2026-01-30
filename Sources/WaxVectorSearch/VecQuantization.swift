import USearch

/// Scalar quantization used for USearch vector storage.
public enum VecQuantization: UInt8, Sendable, Equatable {
    case f32 = 0
    case f16 = 1
    case i8 = 2

    public func toUSearchScalar() -> USearchScalar {
        switch self {
        case .f32:
            return .f32
        case .f16:
            return .f16
        case .i8:
            return .i8
        }
    }
}
