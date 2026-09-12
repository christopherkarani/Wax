import Foundation
import WaxCore
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

enum HostHookWriteFault: Equatable, Sendable {
    case none
    case beforeAnyWrite
    case afterFirstSuccessfulWrite
    case mutateBeforeReplace(Data)
}

struct HostHookWritePlan: Equatable, Sendable {
    var url: URL
    var originalBytes: Data?
    var preimageHash: String
    var renderedBytes: Data
    var originalMode: UInt16
}

struct HostHookTransactionWriter: Sendable {
    var fault: HostHookWriteFault = .none

    func commit(_ plans: [HostHookWritePlan]) throws {
        if case .beforeAnyWrite = fault {
            throw HostHookError.writeFailed("injected write failure")
        }

        var committed: [HostHookWritePlan] = []
        do {
            for (index, plan) in plans.enumerated() {
                try replace(plan)
                committed.append(plan)
                if fault == .afterFirstSuccessfulWrite && index == 0 {
                    throw HostHookError.writeFailed("injected write failure")
                }
            }
        } catch {
            for plan in committed.reversed() {
                try restore(plan)
            }
            throw error
        }
    }

    static func hash(_ data: Data) -> String {
        SHA256Checksum.digest(data).hexString
    }

    static func posixMode(of url: URL) throws -> UInt16 {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        let raw = attributes[.posixPermissions] as? NSNumber
        return (raw?.uint16Value ?? 0o600) & 0o777
    }

    static func refuseSymlink(_ url: URL) throws {
        if isSymlink(url) {
            throw HostHookError.symlinkConfig
        }
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue {
            return
        }
    }

    static func isSymlink(_ url: URL) -> Bool {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path) else {
            return false
        }
        return attributes[.type] as? FileAttributeType == .typeSymbolicLink
    }

    private func replace(_ plan: HostHookWritePlan) throws {
        let destination = plan.url.standardizedFileURL
        try Self.refuseSymlink(destination)
        try FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Self.refuseSymlink(destination.deletingLastPathComponent())

        let temp = destination.deletingLastPathComponent()
            .appendingPathComponent(".\(destination.lastPathComponent).wax-tmp-\(UUID().uuidString)")
        try writeData(plan.renderedBytes, to: temp, mode: plan.originalMode)
        defer { try? FileManager.default.removeItem(at: temp) }

        if case .mutateBeforeReplace(let userBytes) = fault {
            try userBytes.write(to: destination, options: .atomic)
        }

        try verifyPreimage(plan)

        if FileManager.default.fileExists(atPath: destination.path) {
            try writeBackup(of: plan)
        }

        if FileManager.default.fileExists(atPath: destination.path) {
            _ = try FileManager.default.replaceItemAt(
                destination,
                withItemAt: temp,
                backupItemName: nil,
                options: []
            )
        } else {
            try FileManager.default.moveItem(at: temp, to: destination)
        }

        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: plan.originalMode)],
            ofItemAtPath: destination.path
        )
        try fsyncDirectory(destination.deletingLastPathComponent())
    }

    private func verifyPreimage(_ plan: HostHookWritePlan) throws {
        let exists = FileManager.default.fileExists(atPath: plan.url.path)
        if let original = plan.originalBytes {
            guard exists else {
                throw HostHookError.concurrentModification
            }
            if Self.isSymlink(plan.url) {
                throw HostHookError.symlinkConfig
            }
            let current = try Data(contentsOf: plan.url)
            if Self.hash(current) != plan.preimageHash || current != original {
                throw HostHookError.concurrentModification
            }
        } else if exists {
            throw HostHookError.concurrentModification
        }
    }

    private func writeBackup(of plan: HostHookWritePlan) throws {
        guard let original = plan.originalBytes else { return }
        let backup = URL(fileURLWithPath: plan.url.path + ".waxbak")
        if Self.isSymlink(backup) {
            throw HostHookError.symlinkConfig
        }
        try writeData(original, to: backup, mode: 0o600)
    }

    private func restore(_ plan: HostHookWritePlan) throws {
        if let original = plan.originalBytes {
            try writeData(original, to: plan.url, mode: plan.originalMode)
        } else if FileManager.default.fileExists(atPath: plan.url.path) {
            try FileManager.default.removeItem(at: plan.url)
        }
    }

    private func writeData(_ data: Data, to url: URL, mode: UInt16) throws {
        if Self.isSymlink(url) {
            throw HostHookError.symlinkConfig
        }
        let created = FileManager.default.createFile(
            atPath: url.path,
            contents: nil,
            attributes: [.posixPermissions: NSNumber(value: mode)]
        )
        if !created && !FileManager.default.fileExists(atPath: url.path) {
            throw HostHookError.writeFailed("unable to create file")
        }
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.truncate(atOffset: 0)
        try handle.write(contentsOf: data)
        try handle.synchronize()
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: mode)],
            ofItemAtPath: url.path
        )
    }

    private func fsyncDirectory(_ url: URL) throws {
        let fd = open(url.path, O_RDONLY)
        guard fd >= 0 else {
            throw HostHookError.writeFailed("directory fsync failed")
        }
        defer { close(fd) }
        if fsync(fd) != 0 {
            throw HostHookError.writeFailed("directory fsync failed")
        }
    }
}
