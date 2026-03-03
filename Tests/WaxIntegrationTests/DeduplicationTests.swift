import Foundation
import Testing
import Wax

@Test func rememberIdenticalContentTwiceIsIdempotent() async throws {
    try await TempFiles.withTempFile { url in
        var config = OrchestratorConfig.default
        config.enableVectorSearch = false

        let orchestrator = try await MemoryOrchestrator(at: url, config: config)
        try await orchestrator.remember("Duplicate content test")
        try await orchestrator.flush()

        let afterFirst = await orchestrator.runtimeStats().frameCount

        try await orchestrator.remember("Duplicate content test")
        try await orchestrator.flush()
        let afterSecond = await orchestrator.runtimeStats().frameCount

        #expect(afterSecond == afterFirst)
        try await orchestrator.close()
    }
}

@Test func rememberDifferentContentIncreasesFrameCount() async throws {
    try await TempFiles.withTempFile { url in
        var config = OrchestratorConfig.default
        config.enableVectorSearch = false

        let orchestrator = try await MemoryOrchestrator(at: url, config: config)
        try await orchestrator.remember("First content")
        try await orchestrator.flush()
        let afterFirst = await orchestrator.runtimeStats().frameCount

        try await orchestrator.remember("Second content")
        try await orchestrator.flush()
        let afterSecond = await orchestrator.runtimeStats().frameCount

        #expect(afterSecond > afterFirst)
        try await orchestrator.close()
    }
}
