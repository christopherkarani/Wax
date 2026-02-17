import Foundation
import os

enum WaxDiagnostics {
    private static let logger = Logger(subsystem: "com.wax.framework", category: "diagnostics")

    static func logSwallowed(
        _ error: any Error,
        context: StaticString,
        fallback: StaticString,
        fileID: StaticString = #fileID,
        line: UInt = #line
    ) {
        logger.error(
            "\(context, privacy: .public): \(String(describing: error), privacy: .public); fallback: \(fallback, privacy: .public) [\(fileID, privacy: .public):\(line)]"
        )
    }
}
