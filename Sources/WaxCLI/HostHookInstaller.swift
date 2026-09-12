import Foundation
import Wax

enum HostHookHost: String, Sendable, CaseIterable {
    case claude
    case codex
    case grok
    case cursor
}

extension HostHookHost {
    /// Thin adapter over the canonical host vocabulary.
    var registry: MCPHostRegistry.Host {
        switch self {
        case .claude: return .claude
        case .codex: return .codex
        case .grok: return .grok
        case .cursor: return .cursor
        }
    }
}

enum HostOwnershipLevel: String, Sendable {
    case a
    case b
    case c
}

enum HostHookRole: String, Sendable {
    case prime
    case checkpoint
}

struct HostHookInstallPolicy: Equatable, Sendable {
    var ownership: HostOwnershipLevel = .b
    var enableCursorStartHook: Bool = false
    var requiresLiveInjectionProbe: Bool = true

    static let `default` = HostHookInstallPolicy()
}

struct HostHookTarget: Equatable, Sendable {
    var host: HostHookHost
    var configURL: URL
    var wrapperPath: String
}

struct HostHookDesiredEntry: Equatable, Sendable {
    var eventName: String
    var role: HostHookRole
    var command: String
    var matcher: String?
    var timeoutSeconds: Int?
    var requiresLiveInjectionProbe: Bool
}

struct HostHookPreview: Equatable, Sendable {
    var host: HostHookHost
    var configURL: URL
    var rendered: String
}

struct HostHookInstallResult: Equatable, Sendable {
    var dryRun: Bool
    var mutated: Bool
    var previews: [HostHookPreview]
}

enum HostHookError: Error, Equatable, LocalizedError {
    case malformedJSON
    case unknownSchemaVersion(String)
    case duplicateWaxHooks(String)
    case concurrentModification
    case relativeWrapperPath
    case unsafeWrapperPath
    case symlinkConfig
    case writeFailed(String)
    case unsupportedHost(String)
    case hostConfigCountMismatch
    case validationFailed

    var isUnknownSchemaVersion: Bool {
        if case .unknownSchemaVersion = self { return true }
        return false
    }

    var isMalformedJSON: Bool {
        if case .malformedJSON = self { return true }
        return false
    }

    var isConcurrentModification: Bool {
        if case .concurrentModification = self { return true }
        return false
    }

    var errorDescription: String? {
        switch self {
        case .malformedJSON:
            return "Host hook config is not valid JSON."
        case .unknownSchemaVersion(let version):
            return "Unsupported host hook schema version (\(version)). Refusing to modify the file."
        case .duplicateWaxHooks(let message):
            return "Duplicate or conflicting Wax-managed hooks: \(message)"
        case .concurrentModification:
            return "Host hook config changed while wiring; aborting without overwrite."
        case .relativeWrapperPath:
            return "Hook wrapper path must be absolute."
        case .unsafeWrapperPath:
            return "Hook wrapper path contains unsafe characters."
        case .symlinkConfig:
            return "Refusing to write a symlinked host hook config."
        case .writeFailed(let message):
            return "Host hook write failed: \(message)"
        case .unsupportedHost(let host):
            return "Unsupported host '\(host)'. Supported: \(MCPHostRegistry.wireHookNames.joined(separator: ", "))."
        case .hostConfigCountMismatch:
            return "--host and --config must be paired one-to-one."
        case .validationFailed:
            return "Rendered hook config failed validation before write."
        }
    }
}

enum HostHookCommand {
    static func requireAbsolute(_ path: String) throws {
        guard path.hasPrefix("/") else {
            throw HostHookError.relativeWrapperPath
        }
    }

    static func line(wrapperPath: String, host: HostHookHost, role: HostHookRole) throws -> String {
        try requireAbsolute(wrapperPath)
        let executable = try quote(wrapperPath)
        return "\(executable) mcp run-hook --host \(host.rawValue) --role \(role.rawValue) --wax-hook 1"
    }

    static func quote(_ path: String) throws -> String {
        if path.contains("\0") || path.contains("\n") || path.contains("\r") || path.contains("'") {
            throw HostHookError.unsafeWrapperPath
        }
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789._-+/@:~")
        if path.unicodeScalars.allSatisfy({ allowed.contains($0) }) {
            return path
        }
        return "'\(path)'"
    }
}

enum HostHookInstaller {
    static func desiredEntries(
        host: HostHookHost,
        wrapperPath: String,
        policy: HostHookInstallPolicy = .default
    ) throws -> [HostHookDesiredEntry] {
        try HostHookCommand.requireAbsolute(wrapperPath)
        let registry = host.registry
        let startName = registry.startEventName
        let endName = registry.endEventName

        let matcher = registry.primeMatcher

        var entries: [HostHookDesiredEntry] = []
        let includePrime = registry.includesPrime(enableCursorStartHook: policy.enableCursorStartHook)

        if includePrime {
            entries.append(
                HostHookDesiredEntry(
                    eventName: startName,
                    role: .prime,
                    command: try HostHookCommand.line(wrapperPath: wrapperPath, host: host, role: .prime),
                    matcher: matcher,
                    timeoutSeconds: 2,
                    requiresLiveInjectionProbe: registry.requiresLiveInjectionProbeForPrime && policy.requiresLiveInjectionProbe
                )
            )
        }

        if policy.ownership == .a {
            entries.append(
                HostHookDesiredEntry(
                    eventName: endName,
                    role: .checkpoint,
                    command: try HostHookCommand.line(wrapperPath: wrapperPath, host: host, role: .checkpoint),
                    matcher: nil,
                    timeoutSeconds: 2,
                    requiresLiveInjectionProbe: false
                )
            )
        }
        return entries
    }

    static func install(
        targets: [HostHookTarget],
        dryRun: Bool,
        policy: HostHookInstallPolicy = .default,
        writer: HostHookTransactionWriter = HostHookTransactionWriter()
    ) throws -> HostHookInstallResult {
        var plans: [HostHookWritePlan] = []
        var previews: [HostHookPreview] = []

        for target in targets {
            try HostHookCommand.requireAbsolute(target.wrapperPath)
            try HostHookTransactionWriter.refuseSymlink(target.configURL)

            let entries = try desiredEntries(
                host: target.host,
                wrapperPath: target.wrapperPath,
                policy: policy
            )
            let exists = FileManager.default.fileExists(atPath: target.configURL.path)
            if exists {
                try HostHookTransactionWriter.refuseSymlink(target.configURL)
            } else {
                try HostHookTransactionWriter.refuseSymlink(target.configURL.deletingLastPathComponent())
            }

            if entries.isEmpty {
                if exists {
                    let bytes = try Data(contentsOf: target.configURL)
                    let document = try HostHookJSON.parse(bytes)
                    try HostHookSchema.validate(document, host: target.host)
                    previews.append(
                        HostHookPreview(
                            host: target.host,
                            configURL: target.configURL,
                            rendered: String(decoding: bytes, as: UTF8.self)
                        )
                    )
                }
                continue
            }

            let originalBytes: Data?
            let document: HostHookJSON
            if exists {
                let bytes = try Data(contentsOf: target.configURL)
                originalBytes = bytes
                document = try HostHookJSON.parse(bytes)
            } else {
                originalBytes = nil
                document = HostHookSchema.seed(host: target.host)
            }

            try HostHookSchema.validate(document, host: target.host)
            let merged = try HostHookAdapterRouter.merge(
                host: target.host,
                document: document,
                entries: entries
            )
            let renderedData = merged.rendered()
            let roundTrip = try HostHookJSON.parse(renderedData)
            guard roundTrip == merged else {
                throw HostHookError.validationFailed
            }

            let renderedString = String(decoding: renderedData, as: UTF8.self)
            previews.append(
                HostHookPreview(host: target.host, configURL: target.configURL, rendered: renderedString)
            )

            if let originalBytes, originalBytes == renderedData {
                continue
            }

            let mode: UInt16
            if exists {
                mode = try HostHookTransactionWriter.posixMode(of: target.configURL)
            } else {
                mode = 0o600
            }

            plans.append(
                HostHookWritePlan(
                    url: target.configURL,
                    originalBytes: originalBytes,
                    preimageHash: HostHookTransactionWriter.hash(originalBytes ?? Data()),
                    renderedBytes: renderedData,
                    originalMode: mode
                )
            )
        }

        if dryRun {
            return HostHookInstallResult(dryRun: true, mutated: false, previews: previews)
        }
        if !plans.isEmpty {
            try writer.commit(plans)
        }
        return HostHookInstallResult(dryRun: false, mutated: !plans.isEmpty, previews: previews)
    }
}

enum HostHookSchema {
    static func seed(host: HostHookHost) -> HostHookJSON {
        if host.registry.usesNestedMatcherDocument {
            return .object([])
        }
        return .object([
            HostHookJSONMember(key: "version", value: .number("1")),
            HostHookJSONMember(key: "hooks", value: .object([])),
        ])
    }

    static func validate(_ document: HostHookJSON, host: HostHookHost) throws {
        guard document.objectMembers != nil else {
            throw HostHookError.malformedJSON
        }
        let version = document.value(forKey: "version")
        if !host.registry.usesNestedMatcherDocument, version == nil {
            throw HostHookError.unknownSchemaVersion("missing")
        }
        if let version {
            try acceptVersion(version)
        }
        if let hooks = document.value(forKey: "hooks"), hooks.objectMembers == nil {
            throw HostHookError.malformedJSON
        }
    }

    static func acceptVersion(_ version: HostHookJSON) throws {
        switch version {
        case .number(let lexeme) where lexeme == "1" || lexeme == "1.0":
            return
        case .string("1"):
            return
        case .number(let lexeme):
            throw HostHookError.unknownSchemaVersion(lexeme)
        case .string(let value):
            throw HostHookError.unknownSchemaVersion(value)
        default:
            throw HostHookError.unknownSchemaVersion("unsupported")
        }
    }
}
