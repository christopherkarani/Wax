import Foundation
import Testing
import Wax

@Test
func putTimestampOverridePersists() async throws {
    try await TempFiles.withTempFile { url in
        let wax = try await Wax.create(at: url)
        let ts: Int64 = 1_700_000_000_000

        let frameId = try await wax.put(
            Data("hello".utf8),
            options: FrameMetaSubset(kind: "test"),
            compression: .plain,
            timestampMs: ts
        )

        try await wax.commit()
        try await wax.close()

        let reopened = try await Wax.open(at: url)
        let meta = try await reopened.frameMeta(frameId: frameId)
        #expect(meta.timestamp == ts)
        try await reopened.close()
    }
}

@Test
func putBatchTimestampOverridesPersist() async throws {
    try await TempFiles.withTempFile { url in
        let wax = try await Wax.create(at: url)
        let ts0: Int64 = 1_700_000_000_000
        let ts1: Int64 = 1_700_000_100_000

        let frameIds = try await wax.putBatch(
            [Data("a".utf8), Data("b".utf8)],
            options: [FrameMetaSubset(kind: "a"), FrameMetaSubset(kind: "b")],
            compression: .plain,
            timestampsMs: [ts0, ts1]
        )
        #expect(frameIds.count == 2)

        try await wax.commit()
        try await wax.close()

        let reopened = try await Wax.open(at: url)
        let meta0 = try await reopened.frameMeta(frameId: frameIds[0])
        let meta1 = try await reopened.frameMeta(frameId: frameIds[1])
        #expect(meta0.timestamp == ts0)
        #expect(meta1.timestamp == ts1)
        try await reopened.close()
    }
}

