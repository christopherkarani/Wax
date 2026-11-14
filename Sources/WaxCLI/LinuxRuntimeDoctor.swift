import Foundation
import Wax
import WaxCore
#if os(Linux)
import Glibc
#endif

/// The Linux section of `mcp doctor`: glibc, the built-in embedders, the broker
/// socket directory and the systemd user session.
///
/// `report` is pure so it is tested on every platform; `liveProbes` reads the
/// host on Linux.
enum LinuxRuntimeDoctor {
    struct Probes: Equatable {
        /// "2.39", or nil when the C library is not glibc.
        var glibcVersion: String?
        /// Raw values of the built-in providers this binary was built with, sorted.
        var builtInEmbedders: [String]
        var socketDirectory: String
        /// The directory exists and is writable, or can be created under a writable parent.
        var socketDirectoryWritable: Bool
        var systemdUserSession: Bool
        var systemdUnitPath: String
        var systemdUnitInstalled: Bool
    }

    struct Report: Equatable {
        var lines: [String] = []
        var warnings: [String] = []
        var failures: [String] = []
    }

    static func report(_ probes: Probes, expectVectorRuntime: Bool) -> Report {
        var report = Report()

        if let version = probes.glibcVersion {
            report.lines.append("glibc: \(version)")
            if let numeric = numericVersion(version) {
                if numeric < (2, 29) {
                    report.warnings.append(
                        "glibc \(version) is older than 2.29: posix_spawn cannot set a child's working directory, " +
                            "so commands that run git inside a repository fail. Use glibc 2.34 or later."
                    )
                } else if numeric < (2, 34) {
                    report.warnings.append(
                        "glibc \(version) is older than 2.34: child processes close inherited descriptors by " +
                            "listing /proc/self/fd, which is slower. glibc 2.34 or later is recommended."
                    )
                }
            }
        } else {
            report.lines.append("glibc: not detected")
        }

        if probes.builtInEmbedders.isEmpty {
            report.lines.append("embedders: none built in")
        } else {
            report.lines.append("embedders: \(probes.builtInEmbedders.joined(separator: ", "))")
        }
        if expectVectorRuntime, !probes.builtInEmbedders.contains("minilm") {
            report.warnings.append(
                "this wax-cli was built without the MiniLMEmbeddings trait, so a broker it starts searches text only. " +
                    "Build wax-cli and wax-mcp with MiniLMEmbeddings."
            )
        }

        let writable = probes.socketDirectoryWritable ? "writable" : "not writable"
        report.lines.append("broker socket directory: \(probes.socketDirectory) (\(writable))")
        if !probes.socketDirectoryWritable {
            report.failures.append(
                "The broker cannot create its socket in \(probes.socketDirectory). " +
                    "Make it writable or set WAX_BROKER_DIR to a private writable directory."
            )
        }

        report.lines.append("systemd user session: \(probes.systemdUserSession ? "running" : "not detected")")
        if probes.systemdUnitInstalled {
            report.lines.append("\(ServiceRestartHint.systemdUnitName): installed (\(probes.systemdUnitPath))")
        } else {
            report.lines.append(
                "\(ServiceRestartHint.systemdUnitName): not installed (see Resources/docs/wax-mcp-hosts.md)"
            )
        }
        return report
    }

    /// "2.39" from confstr's "glibc 2.39"; nil for anything else.
    static func glibcVersion(fromConfstr raw: String) -> String? {
        let parts = raw.split(separator: " ")
        guard parts.count == 2, parts[0] == "glibc" else { return nil }
        let version = String(parts[1])
        return numericVersion(version) == nil ? nil : version
    }

    private static func numericVersion(_ version: String) -> (Int, Int)? {
        let components = version.split(separator: ".")
        guard components.count >= 2,
              let major = Int(components[0]),
              let minor = Int(components[1]) else { return nil }
        return (major, minor)
    }

    #if os(Linux)
    static func liveProbes(environment: [String: String]) -> Probes {
        let socketDirectory = AgentBrokerPathing.brokerSocketRoot(environment: environment).standardizedFileURL.path
        let unitPath = ServiceRestartHint.systemdUserUnitPath(environment: environment)
        return Probes(
            glibcVersion: confstrGlibcVersion().flatMap(glibcVersion(fromConfstr:)),
            builtInEmbedders: BuiltInEmbeddingCompiler.bindingIdentities().keys.map(\.rawValue).sorted(),
            socketDirectory: socketDirectory,
            socketDirectoryWritable: isWritableOrCreatable(socketDirectory),
            systemdUserSession: hasSystemdUserManager(environment: environment),
            systemdUnitPath: unitPath,
            systemdUnitInstalled: FileManager.default.fileExists(atPath: unitPath)
        )
    }

    private static func confstrGlibcVersion() -> String? {
        var buffer = [CChar](repeating: 0, count: 64)
        let length = confstr(Int32(_CS_GNU_LIBC_VERSION), &buffer, buffer.count)
        guard length > 0, length <= buffer.count else { return nil }
        return String(decoding: buffer.prefix(length - 1).map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    /// Writable when the directory exists and is writable and searchable, or when
    /// its nearest existing ancestor is, so the broker can create it. Creates nothing.
    private static func isWritableOrCreatable(_ path: String) -> Bool {
        var current = URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL
        while true {
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: current.path, isDirectory: &isDirectory) {
                return isDirectory.boolValue && access(current.path, W_OK | X_OK) == 0
            }
            let parent = current.deletingLastPathComponent().standardizedFileURL
            if parent.path == current.path { return false }
            current = parent
        }
    }

    /// The user's systemd manager listens on `$XDG_RUNTIME_DIR/systemd/private`.
    private static func hasSystemdUserManager(environment: [String: String]) -> Bool {
        guard let runtime = environment["XDG_RUNTIME_DIR"], runtime.hasPrefix("/") else { return false }
        return FileManager.default.fileExists(atPath: runtime + "/systemd/private")
    }
    #endif
}
