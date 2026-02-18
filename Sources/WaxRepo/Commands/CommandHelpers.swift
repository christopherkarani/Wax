#if WaxRepo
import ArgumentParser
import Foundation

/// Resolve the git repository root from a given path by running `git rev-parse --show-toplevel`.
func resolveRepoRoot(_ path: String) throws -> String {
    let expanded = (path as NSString).expandingTildeInPath
    let absolutePath = expanded.hasPrefix("/")
        ? expanded
        : FileManager.default.currentDirectoryPath + "/" + expanded

    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
    process.arguments = ["rev-parse", "--show-toplevel"]
    process.currentDirectoryURL = URL(fileURLWithPath: absolutePath)

    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = Pipe()

    try process.run()

    // Read pipe before waitUntilExit to avoid pipe buffer deadlock.
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()

    guard process.terminationStatus == 0 else {
        throw ValidationError("Not a git repository: \(absolutePath)")
    }
    guard let root = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
          !root.isEmpty else {
        throw ValidationError("Could not determine git repository root")
    }

    return root
}

/// Write a message to stderr.
func writeStderr(_ message: String) {
    guard let data = (message + "\n").data(using: .utf8) else { return }
    FileHandle.standardError.write(data)
}
#endif
