#if WaxRepo
import ArgumentParser
import Foundation
import WaxCore

/// Resolve the git repository root from a given path by running `git rev-parse --show-toplevel`.
func resolveRepoRoot(_ path: String) throws -> String {
    let expanded = (path as NSString).expandingTildeInPath
    let absolutePath = expanded.hasPrefix("/")
        ? expanded
        : FileManager.default.currentDirectoryPath + "/" + expanded

    let process = ChildProcess()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
    process.arguments = ["rev-parse", "--show-toplevel"]
    process.currentDirectoryURL = URL(fileURLWithPath: absolutePath)

    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = Pipe()

    try process.run()

    // Read the pipe before waiting, so a full pipe buffer cannot deadlock git.
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    // git has closed stdout, so it is exiting; the bound only stops a wedged wait.
    guard let status = process.waitForExit(timeout: 30) else {
        throw ValidationError("git rev-parse did not exit in \(absolutePath)")
    }
    guard status == 0 else {
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
