import Foundation

struct MCPInstallRuntime: Equatable {
    let cliPath: String
    let serverPath: String
    let staged: Bool
}

struct MCPSkillInstall: Equatable {
    let skipped: Bool
    let sourcePath: String?
    let stagedPath: String?
    let staged: Bool

    static let skippedResult = MCPSkillInstall(
        skipped: true,
        sourcePath: nil,
        stagedPath: nil,
        staged: false
    )
}

struct MCPRuntimeValidation: Equatable {
    var failures: [String] = []
    var warnings: [String] = []
}

enum Pathing {
    static func expandPath(_ raw: String) -> String {
        let expanded = (raw as NSString).expandingTildeInPath
        return URL(fileURLWithPath: expanded).standardizedFileURL.path
    }

    static func normalizePath(_ raw: String) -> String {
        let expanded = (raw as NSString).expandingTildeInPath
        let base = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        if expanded.hasPrefix("/") {
            return URL(fileURLWithPath: expanded).standardizedFileURL.path
        }
        return base.appendingPathComponent(expanded).standardizedFileURL.path
    }

    static func resolvePath(_ raw: String) throws -> String {
        let path = normalizePath(raw)
        let url = URL(fileURLWithPath: path)
        if FileManager.default.fileExists(atPath: url.path) {
            return url.path
        }
        throw CLIError("Path not found: \(url.path)")
    }

    /// Resolves the `wax-mcp` server binary path using a search order:
    /// 1. Sibling `wax-mcp` next to the running CLI binary (production/npm layout)
    /// 2. `.build/debug/wax-mcp` relative to cwd (development)
    static func resolveDefaultServerPath() -> String {
        // 1. Look next to the running binary
        if let selfPath = Bundle.main.executableURL?.deletingLastPathComponent() {
            let sibling = selfPath.appendingPathComponent("wax-mcp").path
            if FileManager.default.isExecutableFile(atPath: sibling) {
                return sibling
            }
        }
        // 2. Fall back to development build path
        return ".build/debug/wax-mcp"
    }

    static func resolveSelfExecutablePath() throws -> String {
        guard let raw = CommandLine.arguments.first else {
            throw CLIError("Unable to resolve current executable path")
        }

        if raw.contains("/") {
            let path = raw.hasPrefix("/")
                ? raw
                : URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
                    .appendingPathComponent(raw)
                    .standardizedFileURL
                    .path
            return URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL.path
        }

        let lookup = try ProcessRunner.runCaptured(command: "which", arguments: [raw])
        if lookup.status == EXIT_SUCCESS {
            let resolved = lookup.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            if !resolved.isEmpty {
                return URL(fileURLWithPath: resolved).resolvingSymlinksInPath().standardizedFileURL.path
            }
        }
        return raw
    }

    static func prepareMCPInstallRuntime(
        cliPath: String,
        serverPath: String,
        dryRun: Bool
    ) throws -> MCPInstallRuntime {
        let cliBundledDir = bundledRuntimeDirectory(forExecutablePath: cliPath)
        let serverBundledDir = bundledRuntimeDirectory(forExecutablePath: serverPath)

        guard let sourceDir = cliBundledDir ?? serverBundledDir else {
            return MCPInstallRuntime(cliPath: cliPath, serverPath: serverPath, staged: false)
        }

        let targetDir = stableRuntimeDirectory(forPlatformDirectory: sourceDir.lastPathComponent)
        if !dryRun {
            let sourceValidation = try validateRuntimeDirectory(
                sourceDir,
                expectVectorRuntime: true
            )
            if !sourceValidation.failures.isEmpty {
                throw CLIError(sourceValidation.failures.joined(separator: " | "))
            }
            try stageBundledRuntimeIfNeeded(from: sourceDir, to: targetDir)
            let stagedValidation = try validateStagedRuntimeCopy(
                sourceDir: sourceDir,
                targetDir: targetDir,
                expectVectorRuntime: true
            )
            if !stagedValidation.failures.isEmpty {
                throw CLIError(stagedValidation.failures.joined(separator: " | "))
            }
        }

        let effectiveCLI = cliBundledDir == sourceDir
            ? targetDir.appendingPathComponent(URL(fileURLWithPath: cliPath).lastPathComponent).path
            : cliPath
        let effectiveServer = serverBundledDir == sourceDir
            ? targetDir.appendingPathComponent(URL(fileURLWithPath: serverPath).lastPathComponent).path
            : serverPath

        return MCPInstallRuntime(
            cliPath: effectiveCLI,
            serverPath: effectiveServer,
            staged: true
        )
    }

    static func bundledRuntimeDirectory(forExecutablePath path: String) -> URL? {
        let executableURL = URL(fileURLWithPath: normalizePath(path)).standardizedFileURL
        let directoryURL = executableURL.deletingLastPathComponent()
        guard directoryURL.deletingLastPathComponent().lastPathComponent == "dist" else {
            return nil
        }

        let platformName = directoryURL.lastPathComponent
        guard platformName.hasPrefix("darwin-") else {
            return nil
        }

        let cliPath = directoryURL.appendingPathComponent("wax-cli").path
        let serverPath = directoryURL.appendingPathComponent("wax-mcp").path
        guard FileManager.default.isExecutableFile(atPath: cliPath),
              FileManager.default.isExecutableFile(atPath: serverPath)
        else {
            return nil
        }

        return directoryURL
    }

    static func runtimeDirectory(forExecutablePath path: String) -> URL? {
        if let bundled = bundledRuntimeDirectory(forExecutablePath: path) {
            return bundled
        }

        let executableURL = URL(fileURLWithPath: normalizePath(path)).standardizedFileURL
        let directoryURL = executableURL.deletingLastPathComponent()
        let cliPath = directoryURL.appendingPathComponent("wax-cli").path
        let serverPath = directoryURL.appendingPathComponent("wax-mcp").path
        guard FileManager.default.fileExists(atPath: cliPath) || FileManager.default.fileExists(atPath: serverPath) else {
            return nil
        }
        return directoryURL
    }

    static func stableRuntimeDirectory(forPlatformDirectory platformDirectory: String) -> URL {
        let root = ProcessInfo.processInfo.environment["WAX_MCP_INSTALL_ROOT"].flatMap { raw -> URL? in
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }
            return URL(fileURLWithPath: expandPath(trimmed)).standardizedFileURL
        } ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".local", isDirectory: true)
            .appendingPathComponent("share", isDirectory: true)
            .appendingPathComponent("waxmcp", isDirectory: true)
            .appendingPathComponent("runtime", isDirectory: true)

        return root.appendingPathComponent(platformDirectory, isDirectory: true)
    }

    /// Stable skill install path: `~/.local/share/waxmcp/skills/wax-mcp` by default,
    /// or `$WAX_MCP_INSTALL_ROOT/skills/wax-mcp` when the install root is overridden.
    static func stableSkillDirectory(skillName: String = "wax-mcp") -> URL {
        if let raw = ProcessInfo.processInfo.environment["WAX_MCP_INSTALL_ROOT"] {
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                return URL(fileURLWithPath: expandPath(trimmed))
                    .appendingPathComponent("skills", isDirectory: true)
                    .appendingPathComponent(skillName, isDirectory: true)
            }
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".local", isDirectory: true)
            .appendingPathComponent("share", isDirectory: true)
            .appendingPathComponent("waxmcp", isDirectory: true)
            .appendingPathComponent("skills", isDirectory: true)
            .appendingPathComponent(skillName, isDirectory: true)
    }

    static func isValidSkillDirectory(_ url: URL) -> Bool {
        let skillMarkdown = url.appendingPathComponent("SKILL.md")
        return FileManager.default.fileExists(atPath: skillMarkdown.path)
    }

    /// Resolve the wax-mcp operator skill source directory.
    /// Order: `WAX_MCP_SKILL_SOURCE`, npm package `skills/wax-mcp`, repo
    /// `Resources/skills/public/wax-mcp`, already-staged skill path.
    static func resolveWaxMCPSkillSource(
        cliPath: String? = nil,
        serverPath: String? = nil
    ) -> URL? {
        if let raw = ProcessInfo.processInfo.environment["WAX_MCP_SKILL_SOURCE"] {
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                let candidate = URL(fileURLWithPath: expandPath(trimmed)).standardizedFileURL
                if isValidSkillDirectory(candidate) {
                    return candidate
                }
            }
        }

        var candidates: [URL] = []

        let executableHints = [cliPath, serverPath].compactMap { $0 }
        for path in executableHints {
            if let packageRoot = npmPackageRoot(forExecutablePath: path) {
                candidates.append(
                    packageRoot
                        .appendingPathComponent("skills", isDirectory: true)
                        .appendingPathComponent("wax-mcp", isDirectory: true)
                )
            }
        }

        let cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).standardizedFileURL
        candidates.append(
            cwd
                .appendingPathComponent("Resources/skills/public/wax-mcp", isDirectory: true)
        )
        candidates.append(
            cwd
                .appendingPathComponent("skills/wax-mcp", isDirectory: true)
        )

        for path in executableHints {
            candidates.append(contentsOf: skillCandidatesWalkingUp(from: URL(fileURLWithPath: normalizePath(path))))
        }
        candidates.append(contentsOf: skillCandidatesWalkingUp(from: cwd))

        candidates.append(stableSkillDirectory())

        var seen = Set<String>()
        for candidate in candidates {
            let path = candidate.standardizedFileURL.path
            if seen.contains(path) { continue }
            seen.insert(path)
            if isValidSkillDirectory(candidate) {
                return candidate.standardizedFileURL
            }
        }
        return nil
    }

    private static func npmPackageRoot(forExecutablePath path: String) -> URL? {
        guard let runtimeDir = bundledRuntimeDirectory(forExecutablePath: path) else {
            return nil
        }
        // .../package/dist/darwin-arm64 -> package root
        let distDir = runtimeDir.deletingLastPathComponent()
        guard distDir.lastPathComponent == "dist" else { return nil }
        return distDir.deletingLastPathComponent()
    }

    private static func skillCandidatesWalkingUp(from start: URL) -> [URL] {
        var results: [URL] = []
        var current = start.standardizedFileURL
        if !current.hasDirectoryPath {
            current = current.deletingLastPathComponent()
        }
        for _ in 0..<8 {
            results.append(
                current
                    .appendingPathComponent("Resources/skills/public/wax-mcp", isDirectory: true)
            )
            results.append(
                current
                    .appendingPathComponent("skills/wax-mcp", isDirectory: true)
            )
            let parent = current.deletingLastPathComponent()
            if parent.path == current.path { break }
            current = parent
        }
        return results
    }

    static func prepareWaxMCPSkill(
        cliPath: String,
        serverPath: String,
        dryRun: Bool,
        skip: Bool
    ) throws -> MCPSkillInstall {
        if skip {
            return .skippedResult
        }

        let source = resolveWaxMCPSkillSource(cliPath: cliPath, serverPath: serverPath)
        let target = stableSkillDirectory()

        guard let source else {
            return MCPSkillInstall(
                skipped: false,
                sourcePath: nil,
                stagedPath: isValidSkillDirectory(target) ? target.path : nil,
                staged: false
            )
        }

        if source.standardizedFileURL.path == target.standardizedFileURL.path {
            return MCPSkillInstall(
                skipped: false,
                sourcePath: source.path,
                stagedPath: target.path,
                staged: true
            )
        }

        if !dryRun {
            try stageSkillDirectory(from: source, to: target)
        }

        return MCPSkillInstall(
            skipped: false,
            sourcePath: source.path,
            stagedPath: target.path,
            staged: true
        )
    }

    static func stageSkillDirectory(from sourceDir: URL, to targetDir: URL) throws {
        let fm = FileManager.default
        let standardizedSource = sourceDir.standardizedFileURL
        let standardizedTarget = targetDir.standardizedFileURL
        guard isValidSkillDirectory(standardizedSource) else {
            throw CLIError("Skill source is missing SKILL.md: \(standardizedSource.path)")
        }
        guard standardizedSource.path != standardizedTarget.path else { return }

        let parent = standardizedTarget.deletingLastPathComponent()
        try fm.createDirectory(at: parent, withIntermediateDirectories: true)

        let staging = parent.appendingPathComponent(
            ".\(standardizedTarget.lastPathComponent).staging-\(UUID().uuidString)"
        )
        if fm.fileExists(atPath: staging.path) {
            try fm.removeItem(at: staging)
        }
        try fm.copyItem(at: standardizedSource, to: staging)

        if fm.fileExists(atPath: standardizedTarget.path) {
            try fm.removeItem(at: standardizedTarget)
        }
        try fm.moveItem(at: staging, to: standardizedTarget)
    }

    static func stageBundledRuntimeIfNeeded(from sourceDir: URL, to targetDir: URL) throws {
        let fm = FileManager.default
        let standardizedSource = sourceDir.standardizedFileURL
        let standardizedTarget = targetDir.standardizedFileURL
        guard standardizedSource.path != standardizedTarget.path else { return }

        let parent = standardizedTarget.deletingLastPathComponent()
        try fm.createDirectory(at: parent, withIntermediateDirectories: true)

        let staging = parent.appendingPathComponent(".\(standardizedTarget.lastPathComponent).staging-\(UUID().uuidString)")
        if fm.fileExists(atPath: staging.path) {
            try fm.removeItem(at: staging)
        }
        try fm.copyItem(at: standardizedSource, to: staging)
        try adHocSignExecutables(in: staging)
        try refreshRuntimeChecksums(in: staging)

        if fm.fileExists(atPath: standardizedTarget.path) {
            try fm.removeItem(at: standardizedTarget)
        }
        try fm.moveItem(at: staging, to: standardizedTarget)
    }

    static func validateMCPRuntime(
        serverPath: String,
        expectVectorRuntime: Bool
    ) throws -> MCPRuntimeValidation {
        guard let runtimeDirectory = runtimeDirectory(forExecutablePath: serverPath) else {
            return MCPRuntimeValidation()
        }
        return try validateRuntimeDirectory(runtimeDirectory, expectVectorRuntime: expectVectorRuntime)
    }

    private static func validateStagedRuntimeCopy(
        sourceDir: URL,
        targetDir: URL,
        expectVectorRuntime: Bool
    ) throws -> MCPRuntimeValidation {
        var validation = try validateRuntimeDirectory(targetDir, expectVectorRuntime: expectVectorRuntime)
        let sourceEntries = try topLevelRuntimeEntries(in: sourceDir)
        let targetEntries = try topLevelRuntimeEntries(in: targetDir)
        let missing = sourceEntries.subtracting(targetEntries).sorted()
        if !missing.isEmpty {
            validation.failures.append("Staged runtime is missing entries copied from the bundled runtime: \(missing.joined(separator: ", "))")
        }
        return validation
    }

    private static func validateRuntimeDirectory(
        _ directory: URL,
        expectVectorRuntime: Bool
    ) throws -> MCPRuntimeValidation {
        var validation = MCPRuntimeValidation()

        let requiredExecutables = ["wax-cli", "wax-mcp"]
        for executable in requiredExecutables {
            let path = directory.appendingPathComponent(executable).path
            if !FileManager.default.isExecutableFile(atPath: path) {
                validation.failures.append("Runtime is missing executable \(executable) at \(path)")
            }
        }

        for executable in requiredExecutables {
            let executableURL = directory.appendingPathComponent(executable)
            let checksumURL = directory.appendingPathComponent("\(executable).sha256")
            if FileManager.default.fileExists(atPath: checksumURL.path) {
                if !FileManager.default.fileExists(atPath: executableURL.path) {
                    validation.failures.append("Runtime checksum exists for \(executable) but the executable is missing.")
                    continue
                }
                let expected = try readChecksumFile(at: checksumURL)
                let actual = try sha256Hex(for: executableURL)
                if expected.caseInsensitiveCompare(actual) != .orderedSame {
                    validation.failures.append("Runtime checksum mismatch for \(executable) in \(directory.path)")
                }
            }
        }

        let recommendedBundles = [
            "Wax_Wax.bundle",
            "Wax_WaxBertTokenizer.bundle",
            "Wax_WaxVectorSearch.bundle",
            "MetalANNS_MetalANNSCore.bundle",
        ]
        for bundle in recommendedBundles {
            let bundlePath = directory.appendingPathComponent(bundle).path
            if !FileManager.default.fileExists(atPath: bundlePath) {
                validation.warnings.append("Runtime bundle missing: \(bundlePath)")
            }
        }

        if expectVectorRuntime {
            let vectorBundlePath = directory.appendingPathComponent("Wax_WaxVectorSearchMiniLM.bundle").path
            if !FileManager.default.fileExists(atPath: vectorBundlePath) {
                validation.warnings.append("Vector runtime bundle missing: \(vectorBundlePath)")
            }
        }

        return validation
    }

    private static func topLevelRuntimeEntries(in directory: URL) throws -> Set<String> {
        let entries = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )
        return Set(entries.map(\.lastPathComponent))
    }

    private static func readChecksumFile(at url: URL) throws -> String {
        let contents = try String(contentsOf: url, encoding: .utf8)
        guard let token = contents.split(whereSeparator: \.isWhitespace).first else {
            throw CLIError("Checksum file is empty at \(url.path)")
        }
        return String(token)
    }

    private static func refreshRuntimeChecksums(in directory: URL) throws {
        let requiredExecutables = ["wax-cli", "wax-mcp"]
        for executable in requiredExecutables {
            let executableURL = directory.appendingPathComponent(executable)
            guard FileManager.default.fileExists(atPath: executableURL.path) else { continue }
            let digest = try sha256Hex(for: executableURL)
            let checksumURL = directory.appendingPathComponent("\(executable).sha256")
            let contents = "\(digest)  \(executable)\n"
            try contents.write(to: checksumURL, atomically: true, encoding: .utf8)
        }
    }

    private static func sha256Hex(for url: URL) throws -> String {
        let output = try ProcessRunner.runCaptured(command: "shasum", arguments: ["-a", "256", url.path])
        guard output.status == EXIT_SUCCESS,
              let token = output.stdout.split(whereSeparator: \.isWhitespace).first else {
            throw CLIError("Unable to compute sha256 for \(url.path)")
        }
        return String(token)
    }

    private static func adHocSignExecutables(in directory: URL) throws {
        #if os(macOS)
        let fm = FileManager.default
        let entries = try fm.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey, .isExecutableKey],
            options: [.skipsHiddenFiles]
        )
        for entry in entries {
            let values = try entry.resourceValues(forKeys: [.isRegularFileKey, .isExecutableKey])
            guard values.isRegularFile == true, values.isExecutable == true else { continue }
            let status = try ProcessRunner.run(
                command: "/usr/bin/codesign",
                arguments: ["--force", "--sign", "-", entry.path],
                passthrough: false,
                allowNonZeroExit: true
            )
            if status != EXIT_SUCCESS {
                throw CLIError("Failed to ad-hoc sign staged runtime at \(entry.path)")
            }
        }
        #endif
    }
}
