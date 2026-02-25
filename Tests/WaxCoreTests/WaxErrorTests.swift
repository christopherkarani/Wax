import Foundation
import Testing
@testable import WaxCore

@Test func waxErrorDescriptionInvalidFooter() {
    let error: WaxError = .invalidFooter(reason: "test")
    #expect(error.errorDescription?.contains("Invalid footer") == true)
    #expect(error.errorDescription?.contains("test") == true)
}

@Test func waxErrorDescriptionInvalidToc() {
    let error: WaxError = .invalidToc(reason: "bad toc")
    #expect(error.errorDescription?.contains("Invalid TOC") == true)
}

@Test func waxErrorDescriptionEncodingError() {
    let error: WaxError = .encodingError(reason: "too long")
    #expect(error.errorDescription?.contains("Encoding error") == true)
}

@Test func waxErrorDescriptionDecodingError() {
    let error: WaxError = .decodingError(reason: "truncated")
    #expect(error.errorDescription?.contains("Decoding error") == true)
}

@Test func waxErrorDescriptionWalCorruption() {
    let error: WaxError = .walCorruption(offset: 42, reason: "bad crc")
    #expect(error.errorDescription?.contains("WAL corruption") == true)
    #expect(error.errorDescription?.contains("42") == true)
}

@Test func waxErrorDescriptionChecksumMismatch() {
    let error: WaxError = .checksumMismatch("expected vs actual")
    #expect(error.errorDescription?.contains("Checksum mismatch") == true)
}

@Test func waxErrorDescriptionLockUnavailable() {
    let error: WaxError = .lockUnavailable("file in use")
    #expect(error.errorDescription?.contains("Lock unavailable") == true)
}

@Test func waxErrorDescriptionCapacityExceeded() {
    let error: WaxError = .capacityExceeded(limit: 100, requested: 200)
    #expect(error.errorDescription?.contains("Capacity exceeded") == true)
    #expect(error.errorDescription?.contains("100") == true)
    #expect(error.errorDescription?.contains("200") == true)
}

@Test func waxErrorDescriptionFrameNotFound() {
    let error: WaxError = .frameNotFound(frameId: 999)
    #expect(error.errorDescription?.contains("Frame not found") == true)
    #expect(error.errorDescription?.contains("999") == true)
}

@Test func waxErrorDescriptionIo() {
    let error: WaxError = .io("disk full")
    #expect(error.errorDescription?.contains("I/O error") == true)
}

@Test func waxErrorDescriptionWriterBusy() {
    let error: WaxError = .writerBusy
    #expect(error.errorDescription?.contains("Writer session already active") == true)
}

@Test func waxErrorDescriptionWriterTimeout() {
    let error: WaxError = .writerTimeout
    #expect(error.errorDescription?.contains("Timed out") == true)
}
