import Foundation
import Testing
@testable import WaxCore

@Test func identicalContentProducesSameHash() {
    let content = Data("Hello, world!".utf8)
    let hash1 = ContentHasher.hash(content)
    let hash2 = ContentHasher.hash(content)
    #expect(hash1 == hash2)
    #expect(hash1.count == 32)
}

@Test func differentContentProducesDifferentHash() {
    let hash1 = ContentHasher.hash(Data("Hello".utf8))
    let hash2 = ContentHasher.hash(Data("World".utf8))
    #expect(hash1 != hash2)
}
