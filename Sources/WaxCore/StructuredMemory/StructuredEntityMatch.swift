import Foundation

/// Entity match returned by alias resolution.
public struct StructuredEntityMatch: Sendable, Equatable {
    public var id: Int64
    public var key: EntityKey
    public var kind: String

    public init(id: Int64, key: EntityKey, kind: String) {
        self.id = id
        self.key = key
        self.kind = kind
    }
}
