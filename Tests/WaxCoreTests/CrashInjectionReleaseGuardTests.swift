import Foundation
import Testing
@testable import WaxCore

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// Release builds must ignore `WAX_CRASH_INJECT_CHECKPOINT` and complete commit.
/// DEBUG keeps the kill path; that is covered by `WaxCrashHarness`.
@Test
func commitCompletesWithCrashInjectionEnvSetWhenNotDebug() async throws {
#if DEBUG
    return
#else
    let url = TempFiles.uniqueURL()
    defer { try? FileManager.default.removeItem(at: url) }

    setenv("WAX_CRASH_INJECT_CHECKPOINT", "after_toc_write_before_footer", 1)
    defer { unsetenv("WAX_CRASH_INJECT_CHECKPOINT") }

    let wax = try await Wax.create(at: url)
    _ = try await wax.put(Data("crash-inject-release-guard".utf8))
    try await wax.commit()
    let stats = await wax.stats()
    #expect(stats.frameCount == 1)
    try await wax.close()
#endif
}
