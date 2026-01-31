import Foundation

/// Errors that can occur during Wax operations
public enum WaxError: Error, LocalizedError, Sendable {
    case invalidHeader(reason: String)
    case invalidFooter(reason: String)
    case invalidToc(reason: String)
    case encodingError(reason: String)
    case decodingError(reason: String)
    case walCorruption(offset: UInt64, reason: String)
    case checksumMismatch(String)
    case lockUnavailable(String)
    case capacityExceeded(limit: UInt64, requested: UInt64)
    case frameNotFound(frameId: UInt64)
    case io(String)
    case writerBusy
    case writerTimeout

    public var errorDescription: String? {
        switch self {
        case .invalidHeader(let reason):
            return "Invalid header: \(reason)"
        case .invalidFooter(let reason):
            return "Invalid footer: \(reason)"
        case .invalidToc(let reason):
            return "Invalid TOC: \(reason)"
        case .encodingError(let reason):
            return "Encoding error: \(reason)"
        case .decodingError(let reason):
            return "Decoding error: \(reason)"
        case .walCorruption(let offset, let reason):
            return "WAL corruption at offset \(offset): \(reason)"
        case .checksumMismatch(let details):
            return "Checksum mismatch: \(details)"
        case .lockUnavailable(let details):
            return "Lock unavailable: \(details)"
        case .capacityExceeded(let limit, let requested):
            return "Capacity exceeded: limit=\(limit), requested=\(requested)"
        case .frameNotFound(let frameId):
            return "Frame not found: \(frameId)"
        case .io(let details):
            return "I/O error: \(details)"
        case .writerBusy:
            return "Writer session already active"
        case .writerTimeout:
            return "Timed out waiting for writer session"
        }
    }
}
