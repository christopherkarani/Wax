import Foundation

public struct EnrichmentTask: Sendable, Equatable {
    public var frameId: UInt64
    public var text: String

    public init(frameId: UInt64, text: String) {
        self.frameId = frameId
        self.text = text
    }
}

public struct EnrichmentEntity: Sendable, Equatable {
    public var subject: String
    public var predicate: String
    public var object: String

    public init(subject: String, predicate: String, object: String) {
        self.subject = subject
        self.predicate = predicate
        self.object = object
    }
}

public struct EnrichmentResult: Sendable, Equatable {
    public var frameId: UInt64
    public var keywords: [String]
    public var entities: [EnrichmentEntity]

    public init(frameId: UInt64, keywords: [String], entities: [EnrichmentEntity]) {
        self.frameId = frameId
        self.keywords = keywords
        self.entities = entities
    }
}
