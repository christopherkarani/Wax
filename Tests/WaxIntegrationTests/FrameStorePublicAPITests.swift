import Foundation
import Testing
import Wax

@Test
func frameStoreFlushPersistsAcrossReopen() async throws {
    try await TempFiles.withTempFile { url in
        let store = try await FrameStore.create(at: url, walSize: 4 * 1024 * 1024)
        let payload = Data("flush-persist unique-payload".utf8)
        let id = try await store.put(payload, kind: "note", metadata: ["k": "flush"])
        try await store.flush()
        try await store.close()

        let reopened = try await FrameStore.open(at: url)
        let content = try await reopened.content(frameID: id)
        #expect(String(data: content, encoding: .utf8) == "flush-persist unique-payload")
        let frames = try await reopened.frames()
        #expect(frames.contains(where: { $0.id == id && $0.status == .active && $0.kind == "note" }))
        try await reopened.close()
    }
}

@Test
func frameStoreCreatePutReadDeleteRoundTrip() async throws {
    try await TempFiles.withTempFile { url in
        let store = try await FrameStore.create(at: url, walSize: 4 * 1024 * 1024)
        let payload = Data("hello frame store unique-payload".utf8)
        let id = try await store.put(payload, kind: "note", metadata: ["k": "v"])
        // Frame IDs are stable UInt64 values; 0 is a valid first-frame id.
        let content = try await store.content(frameID: id)
        #expect(String(data: content, encoding: .utf8) == "hello frame store unique-payload")
        let frames = try await store.frames()
        #expect(frames.contains(where: { $0.id == id && $0.status == .active && $0.kind == "note" }))
        try await store.delete(frameID: id)
        let after = try await store.frames()
        if let deleted = after.first(where: { $0.id == id }) {
            #expect(deleted.status == .deleted)
        }
        try await store.close()

        let reopened = try await FrameStore.open(at: url)
        let reopenedFrames = try await reopened.frames()
        #expect(reopenedFrames.contains(where: { $0.id == id }))
        try await reopened.close()
    }
}

@Test
func frameStoreCreateOnlyDoesNotHang() async throws {
    try await TempFiles.withTempFile { url in
        let store = try await FrameStore.create(at: url, walSize: 1 * 1024 * 1024)
        try await store.close()
    }
}

@Test
func frameStoreCloseIsIdempotent() async throws {
    try await TempFiles.withTempFile { url in
        let store = try await FrameStore.create(at: url, walSize: 1 * 1024 * 1024)
        try await store.close()
        // Second close is a no-op (does not throw).
        try await store.close()
    }
}

@Test
func frameStoreUseAfterCloseThrows() async throws {
    try await TempFiles.withTempFile { url in
        let store = try await FrameStore.create(at: url, walSize: 1 * 1024 * 1024)
        let id = try await store.put(Data("x".utf8), kind: "note")
        try await store.close()

        await #expect(throws: WaxError.self) {
            _ = try await store.put(Data("y".utf8), kind: "note")
        }
        await #expect(throws: WaxError.self) {
            _ = try await store.content(frameID: id)
        }
        await #expect(throws: WaxError.self) {
            _ = try await store.frames()
        }
        await #expect(throws: WaxError.self) {
            try await store.delete(frameID: id)
        }
    }
}
