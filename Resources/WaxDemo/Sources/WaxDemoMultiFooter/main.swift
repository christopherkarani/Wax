import Foundation
import Wax

@main
struct WaxDemoMultiFooter {
    static func main() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("wax-demo-multi-\(UUID().uuidString)")
            .appendingPathExtension("wax")

        defer { try? FileManager.default.removeItem(at: url) }

        let store = try await FrameStore.create(at: url, walSize: 1024 * 1024)
        let first = try await store.put(
            Data("first durable frame".utf8),
            kind: "demo",
            metadata: ["generation": "1"]
        )
        let second = try await store.put(
            Data("second durable frame".utf8),
            kind: "demo",
            metadata: ["generation": "2"]
        )
        await store.close()

        let reopened = try await FrameStore.open(at: url)
        let frames = await reopened.frames()
        let ids = Set(frames.map(\.id))
        guard ids.contains(first), ids.contains(second) else {
            throw WaxError.io("expected both demo frames after reopening")
        }
        await reopened.close()

        print("File:", url.path)
        print("Frames:", frames.count)
        print("OK")
    }
}
