import Foundation
import WaxCore

extension MemorySemantics {
    /// Walks `path` by dropping string components. Never uses `URL.deletingLastPathComponent`,
    /// which turns empty/`.`/`./` into `../` forever when cwd is missing.
    ///
    /// Linked worktrees (`.git` file with `gitdir: …/worktrees/<name>`) resolve to the
    /// main repository directory name, not the worktree folder basename.
    package static func gitRepositoryRoot(startingAt path: String) -> String? {
        var current = path
        let fileManager = FileManager.default
        for _ in 0..<256 {
            let gitPath = current == "/" ? "/.git" : "\(current)/.git"
            if fileManager.fileExists(atPath: gitPath) {
                return resolveRepositoryRoot(fromGitMarkerAt: gitPath)
            }
            guard let parent = parentDirectoryPath(current) else {
                return nil
            }
            current = parent
        }
        return nil
    }

    /// Resolves the main repository root from a `.git` directory or gitdir file.
    package static func resolveRepositoryRoot(fromGitMarkerAt gitPath: String) -> String? {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: gitPath, isDirectory: &isDirectory) else {
            return nil
        }
        if isDirectory.boolValue {
            return parentDirectoryPath(gitPath)
        }
        guard let gitDir = parseGitdirPointer(at: gitPath) else {
            return nil
        }
        let commonGitDir = stripWorktreesSuffix(fromGitDir: gitDir)
        return parentDirectoryPath(commonGitDir)
    }

    /// Reads `gitdir: <path>` from a `.git` file (linked worktree). Relative paths
    /// resolve against the directory containing the `.git` file.
    package static func parseGitdirPointer(at gitFilePath: String) -> String? {
        guard let raw = try? String(contentsOfFile: gitFilePath, encoding: .utf8) else {
            return nil
        }
        for line in raw.split(whereSeparator: \.isNewline) {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.count >= 7, trimmed.prefix(7).lowercased() == "gitdir:" else {
                continue
            }
            let value = trimmed.dropFirst(7).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty else { continue }
            if value.hasPrefix("/") {
                return normalizeAbsolutePath(value)
            }
            guard let parent = parentDirectoryPath(gitFilePath) else { return nil }
            return normalizeAbsolutePath(parent + "/" + value)
        }
        return nil
    }

    /// `/repo/.git/worktrees/<name>` → `/repo/.git`; otherwise returns `gitDir` unchanged.
    package static func stripWorktreesSuffix(fromGitDir gitDir: String) -> String {
        let marker = "/worktrees/"
        guard let range = gitDir.range(of: marker) else {
            return gitDir
        }
        return String(gitDir[..<range.lowerBound])
    }

    /// Filesystem snapshot of the caller's checkout. Never invents a SHA.
    package static func snapshotGitCheckout(startingAt path: String?) -> GitCheckoutSnapshot {
        guard let path, let start = resolvedAbsoluteDirectoryPath(
            path,
            processDirectoryPath: ""
        ) ?? (path.hasPrefix("/") ? normalizeAbsolutePath(path) : nil) else {
            return GitCheckoutSnapshot()
        }
        guard let gitMarker = gitMarkerPath(startingAt: start) else {
            return GitCheckoutSnapshot()
        }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: gitMarker, isDirectory: &isDirectory) else {
            return GitCheckoutSnapshot()
        }
        let gitDir: String
        let worktree: String?
        if isDirectory.boolValue {
            gitDir = gitMarker
            worktree = nil
        } else {
            guard let pointed = parseGitdirPointer(at: gitMarker) else {
                return GitCheckoutSnapshot()
            }
            gitDir = pointed
            let name = lastPathComponent(parentDirectoryPath(gitMarker) ?? "")
            worktree = (name.isEmpty || name == "/") ? nil : name
        }
        let (sha, branch) = readHead(gitDir: gitDir)
        return GitCheckoutSnapshot(sha: sha, branch: branch, worktree: worktree)
    }

    /// SHA compare only. Returns `.yes`, `.other`, or `.unknown`. Never `.ancestor`, and never starts a process.
    package static func classifyCheckout(
        storedSHA: String?,
        live: GitCheckoutSnapshot
    ) -> OnThisTree {
        guard let stored = normalizeGitSHA(storedSHA), let liveSHA = normalizeGitSHA(live.sha) else {
            return .unknown
        }
        if gitSHA(stored, matches: liveSHA) {
            return .yes
        }
        return .other
    }

    /// One relation per stored SHA. `git merge-base --is-ancestor` runs only for unequal SHAs when `repoRootPath` is set.
    package static func checkoutRelations(
        storedSHAs: some Sequence<String>,
        live: GitCheckoutSnapshot,
        repoRootPath: String?
    ) -> [String: OnThisTree] {
        var relations: [String: OnThisTree] = [:]
        let liveSHA = normalizeGitSHA(live.sha)
        for storedSHA in storedSHAs {
            if relations[storedSHA] != nil { continue }
            let classified = classifyCheckout(storedSHA: storedSHA, live: live)
            if classified == .other,
               let repoRootPath,
               let stored = normalizeGitSHA(storedSHA),
               let liveSHA,
               isGitAncestor(stored, of: liveSHA, repoRootPath: repoRootPath) {
                relations[storedSHA] = .ancestor
            } else {
                relations[storedSHA] = classified
            }
        }
        return relations
    }

    package static func onThisTree(
        storedSHA: String?,
        live: GitCheckoutSnapshot,
        repoRootPath: String? = nil
    ) -> OnThisTree {
        guard let storedSHA else { return .unknown }
        return checkoutRelations(
            storedSHAs: [storedSHA],
            live: live,
            repoRootPath: repoRootPath
        )[storedSHA] ?? .unknown
    }

    package static func looksLandedClaim(metadata: [String: String], text: String) -> Bool {
        if metadata[MemoryMetadataKeys.checkoutStatus] == MemoryCheckoutStatus.landed.rawValue {
            return true
        }
        let lowered = text.lowercased()
        return lowered.contains("strong execute") || lowered.contains("shipped on")
    }

    private static func gitMarkerPath(startingAt path: String) -> String? {
        var current = path
        let fileManager = FileManager.default
        for _ in 0..<256 {
            let gitPath = current == "/" ? "/.git" : "\(current)/.git"
            if fileManager.fileExists(atPath: gitPath) {
                return gitPath
            }
            guard let parent = parentDirectoryPath(current) else {
                return nil
            }
            current = parent
        }
        return nil
    }

    private static func readHead(gitDir: String) -> (sha: String?, branch: String?) {
        let headPath = gitDir + "/HEAD"
        guard let raw = try? String(contentsOfFile: headPath, encoding: .utf8) else {
            return (nil, nil)
        }
        let line = raw.split(whereSeparator: \.isNewline).first
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) } ?? ""
        if line.lowercased().hasPrefix("ref:") {
            let ref = line.dropFirst(4).trimmingCharacters(in: .whitespacesAndNewlines)
            let branch = ref.hasPrefix("refs/heads/")
                ? String(ref.dropFirst("refs/heads/".count))
                : nil
            return (readRefSHA(gitDir: gitDir, ref: ref), branch)
        }
        return (normalizeGitSHA(line), nil)
    }

    private static func readRefSHA(gitDir: String, ref: String) -> String? {
        if let sha = readSHAFile(gitDir + "/" + ref) {
            return sha
        }
        let common = stripWorktreesSuffix(fromGitDir: gitDir)
        if common != gitDir, let sha = readSHAFile(common + "/" + ref) {
            return sha
        }
        if let sha = readPackedRef(gitDir: gitDir, ref: ref) {
            return sha
        }
        if common != gitDir {
            return readPackedRef(gitDir: common, ref: ref)
        }
        return nil
    }

    private static func readSHAFile(_ path: String) -> String? {
        guard let raw = try? String(contentsOfFile: path, encoding: .utf8) else {
            return nil
        }
        let line = raw.split(whereSeparator: \.isNewline).first
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) } ?? ""
        return normalizeGitSHA(line)
    }

    private static func readPackedRef(gitDir: String, ref: String) -> String? {
        guard let raw = try? String(contentsOfFile: gitDir + "/packed-refs", encoding: .utf8) else {
            return nil
        }
        for line in raw.split(whereSeparator: \.isNewline) {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.hasPrefix("#") || trimmed.hasPrefix("^") { continue }
            let parts = trimmed.split(separator: " ", maxSplits: 1)
            guard parts.count == 2, String(parts[1]) == ref else { continue }
            return normalizeGitSHA(String(parts[0]))
        }
        return nil
    }

    private static func normalizeGitSHA(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard trimmed.count >= 7, trimmed.count <= 64,
              trimmed.allSatisfy({ $0.isHexDigit }) else {
            return nil
        }
        return trimmed
    }

    private static func gitSHA(_ lhs: String, matches rhs: String) -> Bool {
        if lhs == rhs { return true }
        let prefix = min(lhs.count, rhs.count)
        guard prefix >= 7 else { return false }
        return lhs.prefix(prefix) == rhs.prefix(prefix)
    }

    private static func isGitAncestor(_ stored: String, of live: String, repoRootPath: String) -> Bool {
        let process = ChildProcess()
        #if os(Linux)
        // git is not always /usr/bin/git on Linux (Nix, Homebrew on Linux, /usr/local).
        guard let git = ExecutableLookup.find("git", environment: ProcessInfo.processInfo.environment) else {
            return false
        }
        process.executableURL = URL(fileURLWithPath: git)
        #else
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        #endif
        process.arguments = ["-C", repoRootPath, "merge-base", "--is-ancestor", stored, live]
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        do {
            try process.run()
        } catch {
            return false
        }
        let deadline = Date().addingTimeInterval(0.2)
        while process.isRunning, Date() < deadline {
            Thread.sleep(forTimeInterval: 0.01)
        }
        if process.isRunning {
            process.terminate()
            return false
        }
        return process.terminationStatus == 0
    }

    static func resolvedAbsoluteDirectoryPath(
        _ path: String,
        processDirectoryPath: String
    ) -> String? {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            return nil
        }
        if trimmed.hasPrefix("/") {
            return normalizeAbsolutePath(trimmed)
        }
        let cwd = processDirectoryPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard cwd.hasPrefix("/") else {
            return nil
        }
        if trimmed == "." || trimmed == "./" {
            return normalizeAbsolutePath(cwd)
        }
        return normalizeAbsolutePath(cwd + "/" + trimmed)
    }

    private static func normalizeAbsolutePath(_ path: String) -> String {
        var parts: [String] = []
        for part in path.split(separator: "/", omittingEmptySubsequences: true) {
            if part == "." { continue }
            if part == ".." {
                if !parts.isEmpty { parts.removeLast() }
                continue
            }
            parts.append(String(part))
        }
        if parts.isEmpty { return "/" }
        return "/" + parts.joined(separator: "/")
    }

    private static func parentDirectoryPath(_ path: String) -> String? {
        if path.isEmpty || path == "." || path == "./" {
            return nil
        }
        var trimmed = path
        while trimmed.count > 1, trimmed.hasSuffix("/") {
            trimmed.removeLast()
        }
        if trimmed == "/" {
            return nil
        }
        guard let slash = trimmed.lastIndex(of: "/") else {
            return nil
        }
        if slash == trimmed.startIndex {
            return "/"
        }
        return String(trimmed[..<slash])
    }

    static func lastPathComponent(_ path: String) -> String {
        if path == "/" { return "/" }
        var trimmed = path
        while trimmed.count > 1, trimmed.hasSuffix("/") {
            trimmed.removeLast()
        }
        guard let slash = trimmed.lastIndex(of: "/") else {
            return trimmed
        }
        return String(trimmed[trimmed.index(after: slash)...])
    }
}
