import Foundation

/// Typed value for a structured fact.
package enum FactValue: Sendable, Equatable, Hashable {
    case string(String)
    case int(Int64)
    case double(Double)
    case bool(Bool)
    case data(Data)
    case timeMs(Int64)
    case entity(EntityKey)
}
