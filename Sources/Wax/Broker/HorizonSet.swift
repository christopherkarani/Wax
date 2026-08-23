import Foundation

/// Selectable ``LayeredRecall/Horizon`` lanes for layered memory search.
package struct HorizonSet: OptionSet, Sendable, Hashable {
    package let rawValue: UInt8

    package init(rawValue: UInt8) {
        self.rawValue = rawValue
    }

    package static let working = HorizonSet(rawValue: 1 << 0)
    package static let episodic = HorizonSet(rawValue: 1 << 1)
    package static let durable = HorizonSet(rawValue: 1 << 2)

    package static let all: HorizonSet = [.working, .episodic, .durable]
}
