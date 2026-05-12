import Foundation

package enum AgentBrokerValue: Sendable, Equatable, Codable {
    case null
    case bool(Bool)
    case int(Int64)
    case double(Double)
    case string(String)
    case array([AgentBrokerValue])
    case object([String: AgentBrokerValue])

    package init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let boolValue = try? container.decode(Bool.self) {
            self = .bool(boolValue)
        } else if let intValue = try? container.decode(Int64.self) {
            self = .int(intValue)
        } else if let doubleValue = try? container.decode(Double.self) {
            self = .double(doubleValue)
        } else if let stringValue = try? container.decode(String.self) {
            self = .string(stringValue)
        } else if let arrayValue = try? container.decode([AgentBrokerValue].self) {
            self = .array(arrayValue)
        } else if let objectValue = try? container.decode([String: AgentBrokerValue].self) {
            self = .object(objectValue)
        } else {
            throw DecodingError.typeMismatch(
                AgentBrokerValue.self,
                .init(codingPath: decoder.codingPath, debugDescription: "Unsupported JSON value")
            )
        }
    }

    package func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null:
            try container.encodeNil()
        case .bool(let value):
            try container.encode(value)
        case .int(let value):
            try container.encode(value)
        case .double(let value):
            try container.encode(value)
        case .string(let value):
            try container.encode(value)
        case .array(let value):
            try container.encode(value)
        case .object(let value):
            try container.encode(value)
        }
    }

    package var stringValue: String? {
        if case .string(let value) = self {
            return value
        }
        return nil
    }

    package var boolValue: Bool? {
        if case .bool(let value) = self {
            return value
        }
        return nil
    }

    package var intValue: Int64? {
        switch self {
        case .int(let value):
            return value
        case .double(let value) where value.rounded() == value:
            return Int64(value)
        default:
            return nil
        }
    }

    package var doubleValue: Double? {
        switch self {
        case .double(let value):
            return value
        case .int(let value):
            return Double(value)
        default:
            return nil
        }
    }

    package var arrayValue: [AgentBrokerValue]? {
        if case .array(let value) = self {
            return value
        }
        return nil
    }

    package var objectValue: [String: AgentBrokerValue]? {
        if case .object(let value) = self {
            return value
        }
        return nil
    }

    package static func from(_ value: String?) -> AgentBrokerValue {
        value.map(Self.string) ?? .null
    }

    package static func from(_ value: Bool?) -> AgentBrokerValue {
        value.map(Self.bool) ?? .null
    }

    package static func from(_ value: Int?) -> AgentBrokerValue {
        value.map { .int(Int64($0)) } ?? .null
    }

    package static func from(_ value: Int64?) -> AgentBrokerValue {
        value.map(Self.int) ?? .null
    }

    package static func from(_ value: UInt64?) -> AgentBrokerValue {
        value.map {
            if $0 > UInt64(Int64.max) {
                return .string(String($0))
            }
            return .int(Int64($0))
        } ?? .null
    }

    package static func from(_ value: Double?) -> AgentBrokerValue {
        value.map(Self.double) ?? .null
    }
}

package struct AgentBrokerRequest: Sendable, Codable, Equatable {
    package var id: String?
    package var command: String
    package var arguments: [String: AgentBrokerValue]

    package init(
        id: String? = nil,
        command: String,
        arguments: [String: AgentBrokerValue] = [:]
    ) {
        self.id = id
        self.command = command
        self.arguments = arguments
    }
}

package struct AgentBrokerResponse: Sendable, Codable, Equatable {
    package var id: String?
    package var ok: Bool
    package var payload: AgentBrokerValue?
    package var error: String?
    package var shouldExit: Bool

    package init(
        id: String? = nil,
        ok: Bool,
        payload: AgentBrokerValue? = nil,
        error: String? = nil,
        shouldExit: Bool = false
    ) {
        self.id = id
        self.ok = ok
        self.payload = payload
        self.error = error
        self.shouldExit = shouldExit
    }
}

package struct AgentBrokerConfiguration: Sendable, Equatable {
    package let brokerExecutablePath: String
    package let storePath: String
    package let sessionRootPath: String
    package let socketPath: String
    package let embedderChoice: String
    package let noEmbedder: Bool
    package let requireVector: Bool
    package let embedderTuning: CommandLineEmbedderRuntimeTuning

    package init(
        brokerExecutablePath: String,
        storePath: String,
        sessionRootPath: String,
        socketPath: String,
        embedderChoice: String,
        noEmbedder: Bool,
        requireVector: Bool,
        embedderTuning: CommandLineEmbedderRuntimeTuning
    ) {
        self.brokerExecutablePath = brokerExecutablePath
        self.storePath = storePath
        self.sessionRootPath = sessionRootPath
        self.socketPath = socketPath
        self.embedderChoice = embedderChoice
        self.noEmbedder = noEmbedder
        self.requireVector = requireVector
        self.embedderTuning = embedderTuning
    }
}

package enum AgentBrokerPathing {
    package static let defaultStorePath = "~/.wax/memory.wax"
    package static let defaultSessionRootPath = "~/.local/share/waxmcp/sessions"

    package static func expandPath(_ raw: String) -> String {
        let expanded = (raw as NSString).expandingTildeInPath
        return URL(fileURLWithPath: expanded).standardizedFileURL.path
    }

    package static func brokerSocketRoot() -> URL {
        let env = ProcessInfo.processInfo.environment
        if let raw = env["WAX_BROKER_DIR"]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !raw.isEmpty {
            return URL(fileURLWithPath: expandPath(raw), isDirectory: true)
        }
        if let raw = env["WAX_CLI_DAEMON_DIR"]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !raw.isEmpty {
            return URL(fileURLWithPath: expandPath(raw), isDirectory: true)
        }

        #if os(iOS) || os(tvOS) || os(watchOS)
        let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return root
            .appendingPathComponent("waxmcp", isDirectory: true)
            .appendingPathComponent("broker", isDirectory: true)
        #else
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".local", isDirectory: true)
            .appendingPathComponent("share", isDirectory: true)
            .appendingPathComponent("waxmcp", isDirectory: true)
            .appendingPathComponent("broker", isDirectory: true)
        #endif
    }

    package static func defaultSessionRoot() -> String {
        let env = ProcessInfo.processInfo.environment
        if let raw = env["WAX_SESSION_ROOT_DIR"]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !raw.isEmpty {
            return expandPath(raw)
        }
        if let raw = env["WAX_SESSION_ROOT"]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !raw.isEmpty {
            return expandPath(raw)
        }
        return expandPath(defaultSessionRootPath)
    }

    package static func resolveBrokerCLIPath(
        currentExecutablePath: String
    ) -> String {
        if let executableURL = resolvedExecutableURL(for: currentExecutablePath) {
            let sibling = executableURL.deletingLastPathComponent().appendingPathComponent("wax-cli").path
            if FileManager.default.isExecutableFile(atPath: sibling) {
                return sibling
            }
        }

        if let resolvedOnPath = resolveExecutableOnPath("wax-cli") {
            return resolvedOnPath
        }
        return "wax-cli"
    }

    package static func configuration(
        brokerExecutablePath: String,
        storePath: String,
        sessionRootPath: String = defaultSessionRootPath,
        socketRootPath: String? = nil,
        embedderChoice: String,
        noEmbedder: Bool,
        requireVector: Bool = false,
        embedderTuning: CommandLineEmbedderRuntimeTuning = .fromEnvironment()
    ) throws -> AgentBrokerConfiguration {
        let expandedStore = expandPath(storePath)
        let expandedSessionRoot = sessionRootPath == defaultSessionRootPath
            ? defaultSessionRoot()
            : expandPath(sessionRootPath)
        let socketRoot = socketRootPath.map { URL(fileURLWithPath: expandPath($0), isDirectory: true) } ?? brokerSocketRoot()
        try FileManager.default.createDirectory(at: socketRoot, withIntermediateDirectories: true)
        let binaryIdentity = executableIdentity(path: brokerExecutablePath)
        let key = "\(expandedStore)|\(expandedSessionRoot)|\(embedderChoice)|\(noEmbedder)|\(requireVector)|\(embedderTuning.brokerCacheKey)|\(binaryIdentity)"
        let socketName = "\(stableHexHash(key)).sock"
        let socketPath = socketRoot.appendingPathComponent(socketName).path

        return AgentBrokerConfiguration(
            brokerExecutablePath: brokerExecutablePath,
            storePath: expandedStore,
            sessionRootPath: expandedSessionRoot,
            socketPath: socketPath,
            embedderChoice: embedderChoice,
            noEmbedder: noEmbedder,
            requireVector: requireVector,
            embedderTuning: embedderTuning
        )
    }

    private static func stableHexHash(_ text: String) -> String {
        var hash: UInt64 = 14695981039346656037
        for byte in text.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1099511628211
        }
        return String(hash, radix: 16)
    }

    private static func executableIdentity(path: String) -> String {
        let expanded = expandPath(path)
        var parts = [expanded]
        if let attributes = try? FileManager.default.attributesOfItem(atPath: expanded) {
            if let size = attributes[.size] {
                parts.append("size=\(size)")
            }
            if let modified = attributes[.modificationDate] as? Date {
                parts.append("mtime=\(modified.timeIntervalSince1970)")
            }
        }
        return parts.joined(separator: "|")
    }

    private static func resolvedExecutableURL(for currentExecutablePath: String) -> URL? {
        let trimmed = currentExecutablePath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let candidatePath: String
        if trimmed.contains("/") {
            candidatePath = expandPath(trimmed)
        } else if let resolvedOnPath = resolveExecutableOnPath(trimmed) {
            candidatePath = resolvedOnPath
        } else {
            return nil
        }

        return URL(fileURLWithPath: candidatePath)
            .resolvingSymlinksInPath()
            .standardizedFileURL
    }

    private static func resolveExecutableOnPath(_ tool: String) -> String? {
        #if os(iOS) || os(tvOS) || os(watchOS)
        nil
        #else
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["which", tool]

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        do {
            try process.run()
        } catch {
            return nil
        }
        process.waitUntilExit()

        guard process.terminationStatus == EXIT_SUCCESS else {
            return nil
        }

        let data = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        let path = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let path, !path.isEmpty else { return nil }
        return path
        #endif
    }
}
