import Foundation
import Wax

@main
struct WaxDemoCorruptTOC {
    static func main() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("wax-demo-corrupt-\(UUID().uuidString)")
            .appendingPathExtension("wax")

        defer { try? FileManager.default.removeItem(at: url) }

        let store = try await FrameStore.create(at: url, walSize: 1024 * 1024)
        _ = try await store.put(
            Data("corruption smoke fixture".utf8),
            kind: "demo",
            metadata: ["demo": "corrupt-open"]
        )
        await store.close()

        let handle = try FileHandle(forWritingTo: url)
        try handle.seek(toOffset: 0)
        try handle.write(contentsOf: Data("not-a-wax-header".utf8))
        try handle.close()

        do {
            _ = try await FrameStore.open(at: url)
            throw WaxError.io("expected corrupted demo store to fail opening")
        } catch {
            print("File:", url.path)
            print("OK: corrupted store rejected")
        }
    }
}
