import Foundation

package struct EnrichmentTask: Sendable, Equatable {
    package var frameId: UInt64
    package var text: String

    package init(frameId: UInt64, text: String) {
        self.frameId = frameId
        self.text = text
    }
}

package struct EnrichmentEntity: Sendable, Equatable {
    package var subject: String
    package var predicate: String
    package var object: String

    package init(subject: String, predicate: String, object: String) {
        self.subject = subject
        self.predicate = predicate
        self.object = object
    }
}

package struct EnrichmentResult: Sendable, Equatable {
    package var frameId: UInt64
    package var keywords: [String]
    package var entities: [EnrichmentEntity]

    package init(frameId: UInt64, keywords: [String], entities: [EnrichmentEntity]) {
        self.frameId = frameId
        self.keywords = keywords
        self.entities = entities
    }
}
