import Foundation

public enum WaxWriterPolicy: Sendable, Equatable {
    case wait
    case fail
    case timeout(Duration)
}
