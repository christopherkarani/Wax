import Foundation
import Testing
@testable import wax_cli

@Suite("HostHookInstaller")
struct HostHookInstallerTests {
    @Test func dryRunDoesNotMutateFilesystem() throws {
        try withTempRoot { root, wrapper in
            let config = try copyFixture("claude/unrelated.json", to: root.appendingPathComponent("settings.json"))
            try FileManager.default.setAttributes([.posixPermissions: 0o640], ofItemAtPath: config.path)
            let before = try snapshot(config)

            let result = try HostHookInstaller.install(
                targets: [target(.claude, config, wrapper)],
                dryRun: true
            )

            #expect(result.dryRun)
            #expect(result.mutated == false)
            #expect(try snapshot(config) == before)
            #expect(FileManager.default.fileExists(atPath: config.path + ".waxbak") == false)
            let rendered = try #require(result.previews.first?.rendered)
            #expect(rendered.contains("--wax-hook 1"))
            #expect(rendered.contains("unrelated-pre"))
            #expect(rendered.contains("unrelated-stop"))
        }
    }

    @Test func unrelatedHooksSurviveInstall() throws {
        try withTempRoot { root, wrapper in
            let config = try copyFixture("claude/unrelated.json", to: root.appendingPathComponent("settings.json"))
            _ = try HostHookInstaller.install(
                targets: [target(.claude, config, wrapper)],
                dryRun: false
            )

            let rendered = try String(contentsOf: config, encoding: .utf8)
            #expect(rendered.contains("echo unrelated-pre"))
            #expect(rendered.contains("echo unrelated-stop"))
            #expect(rendered.contains(#""matcher" : "Bash""#) || rendered.contains(#""matcher": "Bash""#))
            #expect(rendered.contains(#""customFlag""#))
            #expect(eventOrder(in: rendered, events: ["PreToolUse", "Stop", "SessionStart"]) == ["PreToolUse", "Stop", "SessionStart"])
            #expect(rendered.contains("SessionStart"))
            #expect(waxHookCount(in: rendered) == 1)
            #expect(rendered.contains("Stop"))
        }
    }

    @Test func repeatedInstallDoesNotDuplicateWaxHooks() throws {
        try withTempRoot { root, wrapper in
            let config = try copyFixture("claude/unrelated.json", to: root.appendingPathComponent("settings.json"))
            let first = try HostHookInstaller.install(
                targets: [target(.claude, config, wrapper)],
                dryRun: false
            )
            #expect(first.mutated)
            let afterFirst = try String(contentsOf: config, encoding: .utf8)
            #expect(waxHookCount(in: afterFirst) == 1)

            let second = try HostHookInstaller.install(
                targets: [target(.claude, config, wrapper)],
                dryRun: false
            )
            let afterSecond = try String(contentsOf: config, encoding: .utf8)
            #expect(waxHookCount(in: afterSecond) == 1)
            #expect(afterSecond.contains("echo unrelated-pre"))
            #expect(second.mutated == false || afterSecond == afterFirst)
        }
    }

    @Test func equivalentWaxHookIsUpdatedInPlace() throws {
        try withTempRoot { root, wrapper in
            let config = try copyFixture("claude/equivalent-wax.json", to: root.appendingPathComponent("settings.json"))
            _ = try HostHookInstaller.install(
                targets: [target(.claude, config, wrapper)],
                dryRun: false
            )
            let rendered = try String(contentsOf: config, encoding: .utf8)
            #expect(waxHookCount(in: rendered) == 1)
            #expect(rendered.contains(wrapper.path))
            #expect(!rendered.contains("/old/path/wax-cli"))
            #expect(rendered.contains(#""extraKeep""#))
            #expect(rendered.contains(#""extraMeta""#))
            #expect(rendered.contains("echo unrelated-prompt"))
            #expect(rendered.contains("UserPromptSubmit"))
        }
    }

    @Test func duplicateWaxHooksAreRejected() throws {
        try withTempRoot { root, wrapper in
            let config = try copyFixture("claude/duplicate-wax.json", to: root.appendingPathComponent("settings.json"))
            let before = try Data(contentsOf: config)
            #expect(throws: HostHookError.self) {
                _ = try HostHookInstaller.install(
                    targets: [target(.claude, config, wrapper)],
                    dryRun: false
                )
            }
            #expect(try Data(contentsOf: config) == before)
        }
    }

    @Test func injectedWriteFailureRestoresOriginalBytes() throws {
        try withTempRoot { root, wrapper in
            let claude = try copyFixture("claude/unrelated.json", to: root.appendingPathComponent("claude.json"))
            let codex = try copyFixture("codex/unrelated.json", to: root.appendingPathComponent("codex.json"))
            let claudeBefore = try Data(contentsOf: claude)
            let codexBefore = try Data(contentsOf: codex)

            #expect(throws: HostHookError.self) {
                _ = try HostHookInstaller.install(
                    targets: [
                        target(.claude, claude, wrapper),
                        target(.codex, codex, wrapper),
                    ],
                    dryRun: false,
                    writer: HostHookTransactionWriter(fault: .afterFirstSuccessfulWrite)
                )
            }

            #expect(try Data(contentsOf: claude) == claudeBefore)
            #expect(try Data(contentsOf: codex) == codexBefore)
        }
    }

    @Test func unknownSchemaVersionFailsClosed() throws {
        try withTempRoot { root, wrapper in
            let config = try copyFixture("cursor/unknown-version.json", to: root.appendingPathComponent("hooks.json"))
            let before = try Data(contentsOf: config)
            do {
                _ = try HostHookInstaller.install(
                    targets: [target(.cursor, config, wrapper)],
                    dryRun: false
                )
                Issue.record("unknown Cursor schema version must fail closed")
            } catch let error as HostHookError {
                #expect(error.isUnknownSchemaVersion)
            }
            #expect(try Data(contentsOf: config) == before)
        }
    }

    @Test func cursorMissingVersionFailsClosed() throws {
        try withTempRoot { root, wrapper in
            let config = try copyFixture("cursor/missing-version.json", to: root.appendingPathComponent("hooks.json"))
            let before = try Data(contentsOf: config)
            do {
                _ = try HostHookInstaller.install(
                    targets: [target(.cursor, config, wrapper)],
                    dryRun: true
                )
                Issue.record("Cursor config without version must fail closed")
            } catch let error as HostHookError {
                #expect(error.isUnknownSchemaVersion)
            }
            #expect(try Data(contentsOf: config) == before)
        }
    }

    @Test func malformedJSONFailsClosed() throws {
        try withTempRoot { root, wrapper in
            let config = try copyFixture("claude/malformed.json", to: root.appendingPathComponent("settings.json"))
            let before = try Data(contentsOf: config)
            do {
                _ = try HostHookInstaller.install(
                    targets: [target(.claude, config, wrapper)],
                    dryRun: false
                )
                Issue.record("malformed JSON must fail closed")
            } catch let error as HostHookError {
                #expect(error.isMalformedJSON)
            }
            #expect(try Data(contentsOf: config) == before)
        }
    }

    @Test func unknownFieldsArePreserved() throws {
        try withTempRoot { root, wrapper in
            let config = try copyFixture("claude/unknown-fields.json", to: root.appendingPathComponent("settings.json"))
            _ = try HostHookInstaller.install(
                targets: [target(.claude, config, wrapper)],
                dryRun: false
            )
            let parsed = try HostHookJSON.parse(Data(contentsOf: config))
            #expect(parsed.value(forKey: "extraRoot") == .string("keep-me"))
            #expect(parsed.value(forKey: "x-unknown-0") == .bool(false))
            #expect(parsed.value(forKey: "x-unknown-1") == .string("alpha"))
            #expect(parsed.value(forKey: "vendor")?.value(forKey: "keep") == .bool(true))
            #expect(parsed.value(forKey: "vendor")?.value(forKey: "count")?.numberLexeme == "3")

            let hooks = try #require(parsed.value(forKey: "hooks"))
            #expect(hooks.value(forKey: "MyCustomEvent") != nil)
            #expect(hooks.value(forKey: "PreToolUse") != nil)
            #expect(hooks.value(forKey: "SessionStart") != nil)
            #expect(keyOrder(of: hooks).first == "MyCustomEvent")
            #expect(keyOrder(of: hooks).contains("PreToolUse"))
            #expect(keyOrder(of: hooks).last == "SessionStart")

            let custom = try #require(hooks.value(forKey: "MyCustomEvent")?.arrayValue?.first)
            #expect(custom.value(forKey: "extraGroup")?.numberLexeme == "1")
            let handler = try #require(custom.value(forKey: "hooks")?.arrayValue?.first)
            #expect(handler.value(forKey: "extraHandler") == .string("yes"))
        }
    }

    @Test func propertyStyleUnknownFieldPreservation() throws {
        try withTempRoot { root, wrapper in
            var members = [
                HostHookJSONMember(key: "hooks", value: .object([])),
            ]
            for index in 0..<12 {
                members.append(
                    HostHookJSONMember(key: "x-field-\(index)", value: .string("value-\(index)"))
                )
            }
            let config = root.appendingPathComponent("settings.json")
            try HostHookJSON.object(members).rendered().write(to: config)

            _ = try HostHookInstaller.install(
                targets: [target(.claude, config, wrapper)],
                dryRun: false
            )

            let parsed = try HostHookJSON.parse(Data(contentsOf: config))
            for index in 0..<12 {
                #expect(parsed.value(forKey: "x-field-\(index)") == .string("value-\(index)"))
            }
            #expect(keyOrder(of: parsed).contains("hooks"))
            #expect(keyOrder(of: parsed).first == "hooks")
        }
    }

    @Test func neverInstallsStopOrTrustedFlags() throws {
        try withTempRoot { root, wrapper in
            let claude = try copyFixture("claude/unrelated.json", to: root.appendingPathComponent("claude.json"))
            let grok = try copyFixture("grok/unrelated.json", to: root.appendingPathComponent("grok.json"))
            _ = try HostHookInstaller.install(
                targets: [
                    target(.claude, claude, wrapper),
                    target(.grok, grok, wrapper),
                ],
                dryRun: false
            )

            let claudeText = try String(contentsOf: claude, encoding: .utf8)
            let grokText = try String(contentsOf: grok, encoding: .utf8)
            #expect(claudeText.contains(#""Stop""#))
            #expect(waxRoleCount(in: claudeText, role: "prime") == 1)
            #expect(waxRoleCount(in: claudeText, role: "checkpoint") == 0)
            #expect(!claudeText.contains(#""trusted""#))
            #expect(!grokText.contains(#""trusted""#))
            #expect(!grokText.contains("UserPromptSubmit") || grokText.contains("keep-prompt"))
            #expect(!claudeText.contains("--cwd"))
            #expect(!claudeText.contains("--conversation-id"))
            #expect(!claudeText.contains("sk-"))
            #expect(!claudeText.contains("session_id"))
        }
    }

    @Test func cursorDefaultOmitsSessionStartAndSessionEnd() throws {
        try withTempRoot { root, wrapper in
            let config = try copyFixture("cursor/unrelated.json", to: root.appendingPathComponent("hooks.json"))
            let result = try HostHookInstaller.install(
                targets: [target(.cursor, config, wrapper)],
                dryRun: false
            )
            let rendered = try String(contentsOf: config, encoding: .utf8)
            #expect(result.mutated == false)
            #expect(rendered.contains("afterFileEdit"))
            #expect(rendered.contains("./hooks/format.sh"))
            #expect(rendered.contains(#""stop""#))
            #expect(!rendered.contains(#""sessionStart""#))
            #expect(!rendered.contains(#""sessionEnd""#) || rendered.contains("afterFileEdit"))
            #expect(waxHookCount(in: rendered) == 0)
        }
    }

    @Test func cursorStartHookCarriesLiveInjectionProbeFlag() throws {
        try withTempRoot { root, wrapper in
            let config = try copyFixture("cursor/unrelated.json", to: root.appendingPathComponent("hooks.json"))
            let policy = HostHookInstallPolicy(enableCursorStartHook: true, requiresLiveInjectionProbe: true)
            _ = try HostHookInstaller.install(
                targets: [target(.cursor, config, wrapper)],
                dryRun: false,
                policy: policy
            )
            let parsed = try HostHookJSON.parse(Data(contentsOf: config))
            let start = try #require(parsed.value(forKey: "hooks")?.value(forKey: "sessionStart")?.arrayValue)
            #expect(start.count == 1)
            let handler = try #require(start.first)
            #expect(handler.value(forKey: "command")?.stringValue?.contains(wrapper.path) == true)
            #expect(handler.value(forKey: "wax")?.value(forKey: "requiresLiveInjectionProbe") == .bool(true))
            #expect(handler.value(forKey: "trusted") == nil)
            #expect(parsed.value(forKey: "hooks")?.value(forKey: "sessionEnd") == nil)
            #expect(parsed.value(forKey: "hooks")?.value(forKey: "afterFileEdit") != nil)
        }
    }

    @Test func levelAInstallsSessionEndWithoutStop() throws {
        try withTempRoot { root, wrapper in
            let config = try copyFixture("codex/unrelated.json", to: root.appendingPathComponent("hooks.json"))
            _ = try HostHookInstaller.install(
                targets: [target(.codex, config, wrapper)],
                dryRun: false,
                policy: HostHookInstallPolicy(ownership: .a)
            )
            let rendered = try String(contentsOf: config, encoding: .utf8)
            #expect(rendered.contains("SessionStart"))
            #expect(rendered.contains("SessionEnd"))
            #expect(rendered.contains("python3 ./policy.py"))
            #expect(rendered.contains("python3 ./stop.py"))
            #expect(waxRoleCount(in: rendered, role: "prime") == 1)
            #expect(waxRoleCount(in: rendered, role: "checkpoint") == 1)
            #expect(rendered.contains("--role prime"))
            #expect(rendered.contains("--role checkpoint"))
            #expect(!rendered.contains("trusted"))
        }
    }

    @Test func concurrentEditAbortsReplace() throws {
        try withTempRoot { root, wrapper in
            let config = try copyFixture("claude/unrelated.json", to: root.appendingPathComponent("settings.json"))
            let userBytes = Data(#"{ "hooks": { "Stop": [] }, "user": "edit" }"#.utf8)

            do {
                _ = try HostHookInstaller.install(
                    targets: [target(.claude, config, wrapper)],
                    dryRun: false,
                    writer: HostHookTransactionWriter(fault: .mutateBeforeReplace(userBytes))
                )
                Issue.record("concurrent edit must abort")
            } catch let error as HostHookError {
                #expect(error.isConcurrentModification)
            }
            #expect(try Data(contentsOf: config) == userBytes)
        }
    }

    @Test func preservesOriginalModeAndOwnerOnlyBackup() throws {
        try withTempRoot { root, wrapper in
            let config = try copyFixture("claude/unrelated.json", to: root.appendingPathComponent("settings.json"))
            try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: config.path)

            _ = try HostHookInstaller.install(
                targets: [target(.claude, config, wrapper)],
                dryRun: false
            )

            let liveMode = try posixMode(config)
            #expect(liveMode == 0o644)
            let backup = URL(fileURLWithPath: config.path + ".waxbak")
            #expect(FileManager.default.fileExists(atPath: backup.path))
            #expect(try posixMode(backup) == 0o600)
            #expect(try String(contentsOf: backup, encoding: .utf8).contains("unrelated-pre"))
        }
    }

    @Test func rejectsSymlinkConfig() throws {
        try withTempRoot { root, wrapper in
            let real = try copyFixture("claude/unrelated.json", to: root.appendingPathComponent("real.json"))
            let link = root.appendingPathComponent("settings.json")
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)
            let before = try Data(contentsOf: real)
            #expect(throws: HostHookError.self) {
                _ = try HostHookInstaller.install(
                    targets: [target(.claude, link, wrapper)],
                    dryRun: false
                )
            }
            #expect(try Data(contentsOf: real) == before)
        }
    }

    @Test func renderedCommandUsesAbsoluteWrapperWithoutInterpolation() throws {
        try withTempRoot { root, wrapper in
            let config = root.appendingPathComponent("settings.json")
            try Data("{}".utf8).write(to: config)
            let result = try HostHookInstaller.install(
                targets: [target(.claude, config, wrapper)],
                dryRun: true
            )
            let rendered = try #require(result.previews.first?.rendered)
            #expect(rendered.contains("\(wrapper.path) mcp run-hook --host claude --role prime --wax-hook 1"))
            #expect(!rendered.contains("$"))
            #expect(!rendered.contains("`"))
            #expect(!rendered.contains("--cwd"))
        }
    }

    @Test func relativeWrapperPathFailsClosed() throws {
        try withTempRoot { root, _ in
            let config = try copyFixture("claude/unrelated.json", to: root.appendingPathComponent("settings.json"))
            #expect(throws: HostHookError.self) {
                _ = try HostHookInstaller.install(
                    targets: [
                        HostHookTarget(
                            host: .claude,
                            configURL: config,
                            wrapperPath: "wax-cli"
                        )
                    ],
                    dryRun: true
                )
            }
        }
    }

    @Test func wireHooksCommandParsesDocumentedFlags() throws {
        let parsed = try WaxCLI.MCP.WireHooks.parse([
            "--host", "claude",
            "--config", "/tmp/claude-settings.json",
            "--dry-run",
            "--wrapper", "/tmp/wax-cli",
        ])
        #expect(parsed.dryRun)
        #expect(parsed.hosts == ["claude"])
        #expect(parsed.configs == ["/tmp/claude-settings.json"])
        #expect(parsed.wrapper == "/tmp/wax-cli")
    }

    @Test func grokAndCodexPreserveUnrelatedOrdering() throws {
        try withTempRoot { root, wrapper in
            let grok = try copyFixture("grok/unrelated.json", to: root.appendingPathComponent("grok.json"))
            _ = try HostHookInstaller.install(
                targets: [target(.grok, grok, wrapper)],
                dryRun: false
            )
            let rendered = try String(contentsOf: grok, encoding: .utf8)
            #expect(eventOrder(in: rendered, events: ["PreToolUse", "UserPromptSubmit", "SessionStart"]) == [
                "PreToolUse", "UserPromptSubmit", "SessionStart",
            ])
            #expect(!rendered.contains("SessionEnd"))
        }
    }
}

private struct FileSnapshot: Equatable {
    var bytes: Data
    var mode: UInt16
}

private func snapshot(_ url: URL) throws -> FileSnapshot {
    FileSnapshot(bytes: try Data(contentsOf: url), mode: try posixMode(url))
}

private func posixMode(_ url: URL) throws -> UInt16 {
    let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
    let raw = attributes[.posixPermissions] as? NSNumber
    return (raw?.uint16Value ?? 0) & 0o777
}

private func withTempRoot(_ body: (URL, URL) throws -> Void) throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("wax-host-hooks-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let wrapper = root.appendingPathComponent("wax-cli")
    try Data("#!/bin/sh\nexit 0\n".utf8).write(to: wrapper)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: wrapper.path)
    try body(root, wrapper)
}

private func target(_ host: HostHookHost, _ config: URL, _ wrapper: URL) -> HostHookTarget {
    HostHookTarget(host: host, configURL: config, wrapperPath: wrapper.path)
}

private func copyFixture(_ relative: String, to destination: URL) throws -> URL {
    let source = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .appendingPathComponent("Fixtures/hooks")
        .appendingPathComponent(relative)
    try FileManager.default.copyItem(at: source, to: destination)
    return destination
}

private func waxHookCount(in text: String) -> Int {
    text.components(separatedBy: "--wax-hook ").count - 1
}

private func waxRoleCount(in text: String, role: String) -> Int {
    text.components(separatedBy: "--role \(role)").count - 1
}

private func eventOrder(in text: String, events: [String]) -> [String] {
    events
        .compactMap { event -> (String, String.Index)? in
            guard let range = text.range(of: "\"\(event)\"") else { return nil }
            return (event, range.lowerBound)
        }
        .sorted { $0.1 < $1.1 }
        .map(\.0)
}

private func keyOrder(of json: HostHookJSON) -> [String] {
    json.objectMembers?.map(\.key) ?? []
}
