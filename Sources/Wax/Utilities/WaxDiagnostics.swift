import Foundation
#if canImport(os)
import os
#endif

enum WaxDiagnostics {
    #if canImport(os)
    private static let logger = Logger(subsystem: "com.wax.framework", category: "diagnostics")
    #endif

    static func logSwallowed(
        _ error: any Error,
        context: StaticString,
        fallback: StaticString,
        fileID: StaticString = #fileID,
        line: UInt = #line
    ) {
        #if canImport(os)
        logger.error(
            "\(context, privacy: .public): \(String(describing: error), privacy: .public); fallback: \(fallback, privacy: .public) [\(fileID, privacy: .public):\(line)]"
        )
        #else
        let msg = "\(context): \(String(describing: error)); fallback: \(fallback) [\(fileID):\(line)]\n"
        if let data = msg.data(using: .utf8) {
            FileHandle.standardError.write(data)
        }
        #endif
    }
}
