import Foundation
import Testing
import Wax

private func makeSessionConfig(
    text: Bool = false,
    vector: Bool = false,
    structured: Bool = false,
    dimensions: Int? = nil
) -> WaxSession.Config {
    var config = WaxSession.Config()
    config.enableTextSearch = text
    config.enableVectorSearch = vector
    config.enableStructuredMemory = structured
    config.vectorEnginePreference = .cpuOnly
    config.vectorDimensions = dimensions
    return config
}

@Test
func waxSessionRejectsDisabledTextAndStructuredOperations() async throws {
    try await TempFiles.withTempFile { url in
        let wax = try await Wax.create(at: url)
        let session = try await wax.openSession(.readWrite(.fail), config: makeSessionConfig())

        do {
            _ = try await session.searchText(query: "alpha", topK: 1)
            #expect(Bool(false))
        } catch let error as WaxError {
            guard case .io(let reason) = error else {
                #expect(Bool(false))
                return
            }
            #expect(reason == "text search is disabled")
        }

        do {
            _ = try await session.searchTextFTSSyntax(query: "alpha", topK: 1)
            #expect(Bool(false))
        } catch let error as WaxError {
            guard case .io(let reason) = error else {
                #expect(Bool(false))
                return
            }
            #expect(reason == "text search is disabled")
        }

        do {
            _ = try await session.facts(
                about: nil,
                predicate: nil,
                asOf: .latest,
                limit: 1
            )
            #expect(Bool(false))
        } catch let error as WaxError {
            guard case .io(let reason) = error else {
                #expect(Bool(false))
                return
            }
            #expect(reason == "structured memory is disabled")
        }

        await session.close()
        try await wax.close()
    }
}

@Test
func waxSessionRejectsReadOnlyAndClosedWrites() async throws {
    try await TempFiles.withTempFile { url in
        let wax = try await Wax.create(at: url)
        let reader = try await wax.openSession(.readOnly, config: makeSessionConfig())

        do {
            _ = try await reader.put(Data("denied".utf8))
            #expect(Bool(false))
        } catch let error as WaxError {
            guard case .io(let reason) = error else {
                #expect(Bool(false))
                return
            }
            #expect(reason == "session is read-only")
        }

        let writer = try await wax.openSession(.readWrite(.fail), config: makeSessionConfig())
        await writer.close()

        do {
            _ = try await writer.put(Data("closed".utf8))
            #expect(Bool(false))
        } catch let error as WaxError {
            guard case .io(let reason) = error else {
                #expect(Bool(false))
                return
            }
            #expect(reason == "session is closed")
        }

        await reader.close()
        try await wax.close()
    }
}

@Test
func waxSessionPutBatchValidatesCountsBeforeWriting() async throws {
    try await TempFiles.withTempFile { url in
        let wax = try await Wax.create(at: url)
        let session = try await wax.openSession(.readWrite(.fail), config: makeSessionConfig())

        do {
            _ = try await session.putBatch(
                contents: [Data("a".utf8)],
                embeddings: [[1, 0], [0, 1]],
                options: [FrameMetaSubset()]
            )
            #expect(Bool(false))
        } catch let error as WaxError {
            guard case .encodingError(let reason) = error else {
                #expect(Bool(false))
                return
            }
            #expect(reason.contains("contents.count != embeddings.count"))
        }

        do {
            _ = try await session.putBatch(
                contents: [Data("a".utf8)],
                embeddings: [[1, 0]],
                options: []
            )
            #expect(Bool(false))
        } catch let error as WaxError {
            guard case .encodingError(let reason) = error else {
                #expect(Bool(false))
                return
            }
            #expect(reason.contains("contents.count != options.count"))
        }

        do {
            _ = try await session.putBatch(
                contents: [Data("a".utf8)],
                embeddings: [[1, 0]],
                options: [FrameMetaSubset()],
                timestampsMs: [],
                compression: .plain
            )
            #expect(Bool(false))
        } catch let error as WaxError {
            guard case .encodingError(let reason) = error else {
                #expect(Bool(false))
                return
            }
            #expect(reason.contains("contents.count != timestampsMs.count"))
        }

        do {
            _ = try await session.put(
                Data("mismatch".utf8),
                embedding: [1, 2],
                identity: EmbeddingIdentity(provider: "p", model: "m", dimensions: 3, normalized: true)
            )
            #expect(Bool(false))
        } catch let error as WaxError {
            guard case .io(let reason) = error else {
                #expect(Bool(false))
                return
            }
            #expect(reason.contains("dimension mismatch"))
        }

        await session.close()
        try await wax.close()
    }
}

@Test
func waxSessionStageRequiresConfiguredVectorEngineWhenPendingEmbeddingsExist() async throws {
    try await TempFiles.withTempFile { url in
        let wax = try await Wax.create(at: url)
        let config = makeSessionConfig(text: false, vector: true, structured: false, dimensions: nil)
        let session = try await wax.openSession(.readWrite(.fail), config: config)

        let frameId = try await session.put(Data("pending".utf8))
        try await wax.putEmbedding(frameId: frameId, vector: [1, 0])

        do {
            try await session.stage()
            #expect(Bool(false))
        } catch let error as WaxError {
            guard case .io(let reason) = error else {
                #expect(Bool(false))
                return
            }
            #expect(reason.contains("set vectorDimensions"))
        }

        await session.close()

        do {
            try await wax.close()
        } catch {
            // Closing can fail here because we intentionally left pending embeddings
            // without a staged vector index.
        }
    }
}

@Test
func waxSessionAcceptsTimeoutWriterPolicy() async throws {
    try await TempFiles.withTempFile { url in
        let wax = try await Wax.create(at: url)
        let session = try await wax.openSession(
            .readWrite(.timeout(.seconds(1))),
            config: makeSessionConfig()
        )
        await session.close()
        try await wax.close()
    }
}
