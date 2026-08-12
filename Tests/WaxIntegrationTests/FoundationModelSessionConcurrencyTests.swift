#if canImport(FoundationModels)
import Foundation
import FoundationModels
import Testing
@testable import Wax

@Suite("FoundationModelSessionConcurrencyTests")
struct FoundationModelSessionConcurrencyTests {
    @Test
    func twoConcurrentRespondCallsNeverOverlap() async throws {
        guard #available(macOS 26.0, iOS 26.0, visionOS 26.0, *) else { return }

        try await TempFiles.withTempFile { url in
            let memory = try await Memory(at: url) { $0.enableVectorSearch = false }
            let generator = ControllableFoundationModelGenerator(delay: .milliseconds(80))
            var configuration = FoundationModelsMemorySessionConfig.default
            configuration.embeddingPolicy = .never
            configuration.persistencePolicy = .none
            configuration.includeMemoryTools = false
            configuration.contextStrategy = .promptAugmentation

            let session = WaxFoundationModelSession(
                memory: memory,
                configuration: configuration,
                generator: generator
            )

            async let first = session.respond(to: "first")
            async let second = session.respond(to: "second")
            let (firstReply, secondReply) = try await (first, second)

            #expect(firstReply.contains("first"))
            #expect(secondReply.contains("second"))
            #expect(await generator.maxInFlight() == 1)
            #expect(await generator.completedPrompts() == ["first", "second"])

            try await session.close()
            try await memory.close()
        }
    }

    @Test
    func streamConsumptionHoldsGenerationLease() async throws {
        guard #available(macOS 26.0, iOS 26.0, visionOS 26.0, *) else { return }

        try await TempFiles.withTempFile { url in
            let memory = try await Memory(at: url) { $0.enableVectorSearch = false }
            let generator = ControllableFoundationModelGenerator(delay: .milliseconds(120))
            var configuration = FoundationModelsMemorySessionConfig.default
            configuration.embeddingPolicy = .never
            configuration.persistencePolicy = .none
            configuration.includeMemoryTools = false
            configuration.contextStrategy = .promptAugmentation

            let session = WaxFoundationModelSession(
                memory: memory,
                configuration: configuration,
                generator: generator
            )

            let stream = try await session.streamResponse(to: "stream-A")
            let second = Task { try await session.respond(to: "respond-B") }
            try await generator.waitUntilGenerating()
            #expect(await generator.maxInFlight() == 1)
            #expect(await generator.completedPrompts().isEmpty)

            var chunks: [String] = []
            for try await chunk in stream {
                chunks.append(chunk)
            }
            #expect(!chunks.isEmpty)
            _ = try await second.value

            #expect(await generator.maxInFlight() == 1)
            #expect(await generator.completedPrompts() == ["stream-A", "respond-B"])

            try await session.close()
            try await memory.close()
        }
    }

    @Test
    func streamResponseAndCollectSerializesWithRespond() async throws {
        guard #available(macOS 26.0, iOS 26.0, visionOS 26.0, *) else { return }

        try await TempFiles.withTempFile { url in
            let memory = try await Memory(at: url) { $0.enableVectorSearch = false }
            let generator = ControllableFoundationModelGenerator(delay: .milliseconds(80))
            var configuration = FoundationModelsMemorySessionConfig.default
            configuration.embeddingPolicy = .never
            configuration.persistencePolicy = .none
            configuration.includeMemoryTools = false
            configuration.contextStrategy = .promptAugmentation

            let session = WaxFoundationModelSession(
                memory: memory,
                configuration: configuration,
                generator: generator
            )

            async let collected = session.streamResponseAndCollect(to: "collect-A")
            async let plain = session.respond(to: "respond-B")
            let (collectedReply, plainReply) = try await (collected, plain)

            #expect(collectedReply.content.contains("collect-A"))
            #expect(plainReply.contains("respond-B"))
            #expect(await generator.maxInFlight() == 1)

            try await session.close()
            try await memory.close()
        }
    }
}
#endif
