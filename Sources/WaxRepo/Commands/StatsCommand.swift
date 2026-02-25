#if WaxRepo
import ArgumentParser
import Darwin
import Dispatch
import Foundation

struct StatsCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "stats",
        abstract: "Show index statistics"
    )

    @Option(name: .customLong("repo-path"), help: "Path to the git repository (default: current directory)")
    var repoPath: String = "."

    mutating func run() throws {
        let command = self
        Task(priority: .userInitiated) {
            do {
                try await command.runStats()
                Darwin.exit(EXIT_SUCCESS)
            } catch {
                writeStderr("Error: \(error)")
                Darwin.exit(EXIT_FAILURE)
            }
        }

        dispatchMain()
    }

    private func runStats() async throws {
        let repoRoot = try resolveRepoRoot(repoPath)
        let waxDir = URL(fileURLWithPath: repoRoot).appendingPathComponent(".wax-repo")
        let storePath = waxDir.appendingPathComponent("store.wax")
        let lastHashFile = waxDir.appendingPathComponent("last-indexed-hash")

        guard FileManager.default.fileExists(atPath: storePath.path) else {
            print("No index found. Run 'wax-repo index' first.")
            return
        }

        let store = try await RepoStore(storeURL: storePath, textOnly: true)
        let stats = await store.stats()

        // Read last indexed hash
        let lastHash: String? = {
            guard let data = try? Data(contentsOf: lastHashFile),
                  let hash = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !hash.isEmpty else {
                return nil
            }
            return hash
        }()

        // Store file size
        let fileSize: String = {
            guard let attrs = try? FileManager.default.attributesOfItem(atPath: storePath.path),
                  let bytes = attrs[.size] as? Int64 else {
                return "unknown"
            }
            return formatBytes(bytes)
        }()

        print("wax-repo index stats")
        print("─────────────────────")
        print("  Repository:    \(repoRoot)")
        print("  Frames:        \(stats.frameCount)")
        print("  Store size:    \(fileSize)")
        if let lastHash {
            print("  Last indexed:  \(lastHash.prefix(12))")
        }

        try await store.close()
    }
}

private func formatBytes(_ bytes: Int64) -> String {
    let units = ["B", "KB", "MB", "GB"]
    var value = Double(bytes)
    var unitIndex = 0
    while value >= 1024 && unitIndex < units.count - 1 {
        value /= 1024
        unitIndex += 1
    }
    if unitIndex == 0 {
        return "\(bytes) B"
    }
    return String(format: "%.1f %@", value, units[unitIndex])
}

#endif
