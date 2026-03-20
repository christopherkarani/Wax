import Foundation
import WaxCore

package enum StoreLockProbe {
    package static func preflightExclusiveAccess(at url: URL, timeout: Duration?) throws {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        let lock = try FileLock.acquire(at: url, mode: .exclusive, timeout: timeout)
        try lock.release()
    }
}
