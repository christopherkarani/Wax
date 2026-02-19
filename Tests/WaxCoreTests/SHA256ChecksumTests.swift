import Foundation
import Testing
@testable import WaxCore

@Test func sha256KnownVectorAbc() {
    let digest = SHA256Checksum.digest(Data("abc".utf8))
    #expect(digest.hexString == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
}

@Test func sha256IncrementalMatchesSingleShot() {
    var incremental = SHA256Checksum()
    incremental.update(Data("a".utf8))
    incremental.update(Data("b".utf8))
    incremental.update(Data("c".utf8))
    let incrementalDigest = incremental.finalize()
    let singleShotDigest = SHA256Checksum.digest(Data("abc".utf8))
    #expect(incrementalDigest == singleShotDigest)
}
