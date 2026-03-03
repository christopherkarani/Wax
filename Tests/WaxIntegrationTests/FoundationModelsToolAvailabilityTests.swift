#if canImport(FoundationModels)
import FoundationModels
import Testing
import Wax

@Test
func foundationModelsMemoryToolFactoryCompilesAndBuildsWhenAvailable() async throws {
    guard #available(macOS 26.0, iOS 26.0, *) else { return }

    try await TempFiles.withTempFile { url in
        var config = OrchestratorConfig.default
        config.enableVectorSearch = false
        let memory = try await MemoryOrchestrator(at: url, config: config)
        let tool = await memory.foundationModelsMemoryTool()
        #expect(tool.name == "waxMemory")
        try await memory.close()
    }
}
#endif
