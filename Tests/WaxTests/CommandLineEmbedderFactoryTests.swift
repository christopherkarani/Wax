import Testing
@testable import Wax

@Suite("Command line embedder factory")
struct CommandLineEmbedderFactoryTests {
    @Test
    func lockWaitTimeoutReadsEnvSeconds() {
        #expect(CommandLineEmbedderFactory.lockWaitTimeout(["WAX_LOCK_TIMEOUT_SECS": "1.5"]) == .milliseconds(1_500))
        #expect(CommandLineEmbedderFactory.lockWaitTimeout(["WAX_LOCK_TIMEOUT_SECS": "0"]) == nil)
        #expect(CommandLineEmbedderFactory.lockWaitTimeout([:]) == .milliseconds(2_000))
    }

    // Every broker and store open reads this; an unbounded value must not trap.
    @Test(arguments: ["inf", "1e19"])
    func lockWaitTimeoutSaturatesUnboundedEnvSeconds(raw: String) {
        let timeout = CommandLineEmbedderFactory.lockWaitTimeout(["WAX_LOCK_TIMEOUT_SECS": raw])
        #expect(timeout == .milliseconds(Int64.max))
    }
}
