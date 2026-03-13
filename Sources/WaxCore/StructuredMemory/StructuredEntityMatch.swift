import Foundation

/// Entity match returned by alias resolution.
package struct StructuredEntityMatch: Sendable, Equatable {
    package var id: Int64
    package var key: EntityKey
    package var kind: String

    package init(id: Int64, key: EntityKey, kind: String) {
        self.id = id
        self.key = key
        self.kind = kind
    }
}
