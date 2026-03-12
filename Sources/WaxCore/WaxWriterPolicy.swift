import Foundation

package enum WaxWriterPolicy: Sendable, Equatable {
    case wait
    case fail
    case timeout(Duration)
}
