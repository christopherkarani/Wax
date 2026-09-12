import Foundation
import Wax

struct HostHookJSONMember: Equatable, Sendable {
    var key: String
    var value: HostHookJSON
}

enum HostHookJSON: Equatable, Sendable {
    case null
    case bool(Bool)
    case number(String)
    case string(String)
    case array([HostHookJSON])
    case object([HostHookJSONMember])

    var objectMembers: [HostHookJSONMember]? {
        if case .object(let members) = self { return members }
        return nil
    }

    var arrayValue: [HostHookJSON]? {
        if case .array(let values) = self { return values }
        return nil
    }

    var stringValue: String? {
        if case .string(let value) = self { return value }
        return nil
    }

    var numberLexeme: String? {
        if case .number(let value) = self { return value }
        return nil
    }

    func value(forKey key: String) -> HostHookJSON? {
        objectMembers?.first(where: { $0.key == key })?.value
    }

    mutating func set(_ key: String, to value: HostHookJSON) {
        var members = objectMembers ?? []
        if let index = members.firstIndex(where: { $0.key == key }) {
            members[index].value = value
        } else {
            members.append(HostHookJSONMember(key: key, value: value))
        }
        self = .object(members)
    }

    mutating func remove(_ key: String) {
        guard var members = objectMembers else { return }
        members.removeAll { $0.key == key }
        self = .object(members)
    }

    static func parse(_ data: Data) throws -> HostHookJSON {
        var parser = try HostHookJSONParser(data: data)
        return try parser.parse()
    }

    func rendered() -> Data {
        var output = String()
        HostHookJSONRenderer.write(self, into: &output, indent: 0)
        output.append("\n")
        return Data(output.utf8)
    }
}

enum HostHookAdapterRouter {
    static func merge(
        host: HostHookHost,
        document: HostHookJSON,
        entries: [HostHookDesiredEntry]
    ) throws -> HostHookJSON {
        if host.registry.usesNestedMatcherDocument {
            return try NestedMatcherHostAdapter.merge(document: document, entries: entries)
        }
        return try CursorHostAdapter.merge(document: document, entries: entries)
    }
}

enum NestedMatcherHostAdapter {
    static func merge(
        document: HostHookJSON,
        entries: [HostHookDesiredEntry]
    ) throws -> HostHookJSON {
        var current = document
        for entry in entries {
            current = try merge(document: current, entry: entry)
        }
        return current
    }

    private static func merge(
        document: HostHookJSON,
        entry: HostHookDesiredEntry
    ) throws -> HostHookJSON {
        let hits = try waxHits(in: document)
        let sameRole = hits.filter { $0.role == entry.role }
        if sameRole.count > 1 {
            throw HostHookError.duplicateWaxHooks("multiple Wax \(entry.role.rawValue) hooks")
        }
        if let hit = sameRole.first {
            if hit.eventName != entry.eventName {
                throw HostHookError.duplicateWaxHooks(
                    "Wax \(entry.role.rawValue) already exists on \(hit.eventName)"
                )
            }
            return try update(document: document, hit: hit, entry: entry)
        }
        return try append(document: document, entry: entry)
    }

    private struct WaxHit {
        var eventName: String
        var groupIndex: Int
        var handlerIndex: Int
        var role: HostHookRole
    }

    private static func waxHits(in document: HostHookJSON) throws -> [WaxHit] {
        guard let hooks = document.value(forKey: "hooks") else { return [] }
        guard let members = hooks.objectMembers else {
            throw HostHookError.malformedJSON
        }
        var hits: [WaxHit] = []
        for member in members {
            guard let groups = member.value.arrayValue else {
                throw HostHookError.malformedJSON
            }
            for (groupIndex, group) in groups.enumerated() {
                guard group.objectMembers != nil else {
                    throw HostHookError.malformedJSON
                }
                guard let handlers = group.value(forKey: "hooks")?.arrayValue else {
                    throw HostHookError.malformedJSON
                }
                for (handlerIndex, handler) in handlers.enumerated() {
                    if let role = HostHookOwnership.role(of: handler) {
                        hits.append(
                            WaxHit(
                                eventName: member.key,
                                groupIndex: groupIndex,
                                handlerIndex: handlerIndex,
                                role: role
                            )
                        )
                    }
                }
            }
        }
        return hits
    }

    private static func update(
        document: HostHookJSON,
        hit: WaxHit,
        entry: HostHookDesiredEntry
    ) throws -> HostHookJSON {
        var root = document
        let hooks = root.value(forKey: "hooks") ?? .object([])
        var hookMembers = try requireObject(hooks)
        guard let eventIndex = hookMembers.firstIndex(where: { $0.key == hit.eventName }) else {
            throw HostHookError.validationFailed
        }
        var groups = try requireArray(hookMembers[eventIndex].value)
        var group = groups[hit.groupIndex]
        var handlers = try requireArray(group.value(forKey: "hooks") ?? .array([]))
        handlers[hit.handlerIndex] = HostHookOwnership.updateHandler(
            handlers[hit.handlerIndex],
            with: entry,
            includeType: true
        )
        group.set("hooks", to: .array(handlers))
        groups[hit.groupIndex] = group
        hookMembers[eventIndex].value = .array(groups)
        root.set("hooks", to: .object(hookMembers))
        return root
    }

    private static func append(
        document: HostHookJSON,
        entry: HostHookDesiredEntry
    ) throws -> HostHookJSON {
        var root = document
        var hooks = root.value(forKey: "hooks") ?? .object([])
        if hooks.objectMembers == nil {
            throw HostHookError.malformedJSON
        }
        let group = makeGroup(entry)
        if var groups = hooks.value(forKey: entry.eventName)?.arrayValue {
            groups.append(group)
            hooks.set(entry.eventName, to: .array(groups))
        } else if hooks.value(forKey: entry.eventName) != nil {
            throw HostHookError.malformedJSON
        } else {
            hooks.set(entry.eventName, to: .array([group]))
        }
        root.set("hooks", to: hooks)
        return root
    }

    private static func makeGroup(_ entry: HostHookDesiredEntry) -> HostHookJSON {
        var members: [HostHookJSONMember] = []
        if let matcher = entry.matcher {
            members.append(HostHookJSONMember(key: "matcher", value: .string(matcher)))
        }
        members.append(
            HostHookJSONMember(
                key: "hooks",
                value: .array([HostHookOwnership.makeHandler(entry, includeType: true)])
            )
        )
        return .object(members)
    }
}

enum CursorHostAdapter {
    static func merge(
        document: HostHookJSON,
        entries: [HostHookDesiredEntry]
    ) throws -> HostHookJSON {
        var current = document
        for entry in entries {
            current = try merge(document: current, entry: entry)
        }
        return current
    }

    private static func merge(
        document: HostHookJSON,
        entry: HostHookDesiredEntry
    ) throws -> HostHookJSON {
        let hits = try waxHits(in: document)
        let sameRole = hits.filter { $0.role == entry.role }
        if sameRole.count > 1 {
            throw HostHookError.duplicateWaxHooks("multiple Wax \(entry.role.rawValue) hooks")
        }
        if let hit = sameRole.first {
            if hit.eventName != entry.eventName {
                throw HostHookError.duplicateWaxHooks(
                    "Wax \(entry.role.rawValue) already exists on \(hit.eventName)"
                )
            }
            return try update(document: document, hit: hit, entry: entry)
        }
        return try append(document: document, entry: entry)
    }

    private struct WaxHit {
        var eventName: String
        var handlerIndex: Int
        var role: HostHookRole
    }

    private static func waxHits(in document: HostHookJSON) throws -> [WaxHit] {
        guard let hooks = document.value(forKey: "hooks") else { return [] }
        guard let members = hooks.objectMembers else {
            throw HostHookError.malformedJSON
        }
        var hits: [WaxHit] = []
        for member in members {
            guard let handlers = member.value.arrayValue else {
                throw HostHookError.malformedJSON
            }
            for (handlerIndex, handler) in handlers.enumerated() {
                guard handler.objectMembers != nil else {
                    throw HostHookError.malformedJSON
                }
                if let role = HostHookOwnership.role(of: handler) {
                    hits.append(WaxHit(eventName: member.key, handlerIndex: handlerIndex, role: role))
                }
            }
        }
        return hits
    }

    private static func update(
        document: HostHookJSON,
        hit: WaxHit,
        entry: HostHookDesiredEntry
    ) throws -> HostHookJSON {
        var root = document
        let hooks = root.value(forKey: "hooks") ?? .object([])
        var hookMembers = try requireObject(hooks)
        guard let eventIndex = hookMembers.firstIndex(where: { $0.key == hit.eventName }) else {
            throw HostHookError.validationFailed
        }
        var handlers = try requireArray(hookMembers[eventIndex].value)
        handlers[hit.handlerIndex] = HostHookOwnership.updateHandler(
            handlers[hit.handlerIndex],
            with: entry,
            includeType: false
        )
        hookMembers[eventIndex].value = .array(handlers)
        root.set("hooks", to: .object(hookMembers))
        return root
    }

    private static func append(
        document: HostHookJSON,
        entry: HostHookDesiredEntry
    ) throws -> HostHookJSON {
        var root = document
        var hooks = root.value(forKey: "hooks") ?? .object([])
        if hooks.objectMembers == nil {
            throw HostHookError.malformedJSON
        }
        let handler = HostHookOwnership.makeHandler(entry, includeType: false)
        if var handlers = hooks.value(forKey: entry.eventName)?.arrayValue {
            handlers.append(handler)
            hooks.set(entry.eventName, to: .array(handlers))
        } else if hooks.value(forKey: entry.eventName) != nil {
            throw HostHookError.malformedJSON
        } else {
            hooks.set(entry.eventName, to: .array([handler]))
        }
        root.set("hooks", to: hooks)
        return root
    }
}

enum HostHookOwnership {
    static func role(of handler: HostHookJSON) -> HostHookRole? {
        if handler.value(forKey: "wax")?.value(forKey: "owner") == .string("wax") {
            if let role = handler.value(forKey: "wax")?.value(forKey: "role")?.stringValue,
               let parsed = HostHookRole(rawValue: role) {
                return parsed
            }
        }
        guard let command = handler.value(forKey: "command")?.stringValue,
              command.contains("--wax-hook") else {
            return nil
        }
        if command.contains("--role prime") {
            return .prime
        }
        if command.contains("--role checkpoint") {
            return .checkpoint
        }
        return nil
    }

    static func makeHandler(_ entry: HostHookDesiredEntry, includeType: Bool) -> HostHookJSON {
        var members: [HostHookJSONMember] = []
        if includeType {
            members.append(HostHookJSONMember(key: "type", value: .string("command")))
        }
        members.append(HostHookJSONMember(key: "command", value: .string(entry.command)))
        if let timeout = entry.timeoutSeconds {
            members.append(HostHookJSONMember(key: "timeout", value: .number(String(timeout))))
        }
        members.append(HostHookJSONMember(key: "wax", value: marker(for: entry)))
        return .object(members)
    }

    static func updateHandler(
        _ handler: HostHookJSON,
        with entry: HostHookDesiredEntry,
        includeType: Bool
    ) -> HostHookJSON {
        var updated = handler
        if includeType {
            updated.set("type", to: .string("command"))
        }
        updated.set("command", to: .string(entry.command))
        updated.remove("trusted")
        var wax = updated.value(forKey: "wax") ?? .object([])
        if wax.objectMembers == nil {
            wax = .object([])
        }
        wax.set("owner", to: .string("wax"))
        wax.set("version", to: .number("1"))
        wax.set("role", to: .string(entry.role.rawValue))
        wax.remove("trusted")
        if entry.requiresLiveInjectionProbe {
            wax.set("requiresLiveInjectionProbe", to: .bool(true))
        }
        updated.set("wax", to: wax)
        return updated
    }

    private static func marker(for entry: HostHookDesiredEntry) -> HostHookJSON {
        var members = [
            HostHookJSONMember(key: "owner", value: .string("wax")),
            HostHookJSONMember(key: "version", value: .number("1")),
            HostHookJSONMember(key: "role", value: .string(entry.role.rawValue)),
        ]
        if entry.requiresLiveInjectionProbe {
            members.append(
                HostHookJSONMember(key: "requiresLiveInjectionProbe", value: .bool(true))
            )
        }
        return .object(members)
    }
}

private func requireObject(_ value: HostHookJSON) throws -> [HostHookJSONMember] {
    guard let members = value.objectMembers else {
        throw HostHookError.malformedJSON
    }
    return members
}

private func requireArray(_ value: HostHookJSON) throws -> [HostHookJSON] {
    guard let values = value.arrayValue else {
        throw HostHookError.malformedJSON
    }
    return values
}

private struct HostHookJSONParser {
    let text: String
    var index: String.Index

    init(data: Data) throws {
        guard let text = String(data: data, encoding: .utf8) else {
            throw HostHookError.malformedJSON
        }
        self.text = text
        self.index = text.startIndex
    }

    mutating func parse() throws -> HostHookJSON {
        skipBOM()
        skipWhitespace()
        let value = try parseValue(depth: 0)
        skipWhitespace()
        guard index == text.endIndex else {
            throw HostHookError.malformedJSON
        }
        return value
    }

    private mutating func parseValue(depth: Int) throws -> HostHookJSON {
        guard depth <= 32 else {
            throw HostHookError.malformedJSON
        }
        skipWhitespace()
        guard let character = peek() else {
            throw HostHookError.malformedJSON
        }
        switch character {
        case "n":
            try expect("null")
            return .null
        case "t":
            try expect("true")
            return .bool(true)
        case "f":
            try expect("false")
            return .bool(false)
        case "\"":
            return .string(try parseString())
        case "{":
            return try parseObject(depth: depth)
        case "[":
            return try parseArray(depth: depth)
        case "-", "0"..."9":
            return .number(try parseNumber())
        default:
            throw HostHookError.malformedJSON
        }
    }

    private mutating func parseObject(depth: Int) throws -> HostHookJSON {
        try expect("{")
        skipWhitespace()
        var members: [HostHookJSONMember] = []
        var seen = Set<String>()
        if peek() == "}" {
            advance()
            return .object(members)
        }
        while true {
            skipWhitespace()
            let key = try parseString()
            if seen.contains(key) {
                throw HostHookError.malformedJSON
            }
            seen.insert(key)
            skipWhitespace()
            try expect(":")
            skipWhitespace()
            let value = try parseValue(depth: depth + 1)
            members.append(HostHookJSONMember(key: key, value: value))
            skipWhitespace()
            if peek() == "," {
                advance()
                continue
            }
            try expect("}")
            return .object(members)
        }
    }

    private mutating func parseArray(depth: Int) throws -> HostHookJSON {
        try expect("[")
        skipWhitespace()
        var values: [HostHookJSON] = []
        if peek() == "]" {
            advance()
            return .array(values)
        }
        while true {
            values.append(try parseValue(depth: depth + 1))
            skipWhitespace()
            if peek() == "," {
                advance()
                continue
            }
            try expect("]")
            return .array(values)
        }
    }

    private mutating func parseString() throws -> String {
        try expect("\"")
        var result = String()
        while let character = peek() {
            if character == "\"" {
                advance()
                return result
            }
            if character == "\\" {
                advance()
                result.append(try parseEscape())
                continue
            }
            if character == "\u{00}" || character.unicodeScalars.contains(where: { $0.value < 0x20 }) {
                throw HostHookError.malformedJSON
            }
            result.append(character)
            advance()
        }
        throw HostHookError.malformedJSON
    }

    private mutating func parseEscape() throws -> Character {
        guard let character = peek() else {
            throw HostHookError.malformedJSON
        }
        advance()
        switch character {
        case "\"", "\\", "/":
            return character
        case "b":
            return "\u{08}"
        case "f":
            return "\u{0C}"
        case "n":
            return "\n"
        case "r":
            return "\r"
        case "t":
            return "\t"
        case "u":
            let lead = try parseUnicodeScalar()
            if UTF16.isLeadSurrogate(lead) {
                // A lead surrogate is only valid as half of a pair.
                guard peek() == "\\" else { throw HostHookError.malformedJSON }
                advance()
                try expect("u")
                let trail = try parseUnicodeScalar()
                guard UTF16.isTrailSurrogate(trail) else {
                    throw HostHookError.malformedJSON
                }
                let decoded = String(decoding: [lead, trail], as: UTF16.self)
                guard decoded.count == 1, let combined = decoded.first else {
                    throw HostHookError.malformedJSON
                }
                return combined
            }
            guard !UTF16.isTrailSurrogate(lead), let scalar = UnicodeScalar(UInt32(lead)) else {
                throw HostHookError.malformedJSON
            }
            return Character(scalar)
        default:
            throw HostHookError.malformedJSON
        }
    }

    private mutating func parseUnicodeScalar() throws -> UInt16 {
        var value: UInt32 = 0
        for _ in 0..<4 {
            guard let character = peek(), let nibble = hexValue(character) else {
                throw HostHookError.malformedJSON
            }
            advance()
            value = (value << 4) | nibble
        }
        guard let scalar = UInt16(exactly: value) else {
            throw HostHookError.malformedJSON
        }
        return scalar
    }

    private mutating func parseNumber() throws -> String {
        let start = index
        if peek() == "-" {
            advance()
        }
        guard let first = peek() else {
            throw HostHookError.malformedJSON
        }
        if first == "0" {
            advance()
            if let next = peek(), isDigit(next) {
                throw HostHookError.malformedJSON
            }
        } else if isDigit(first) {
            while let next = peek(), isDigit(next) {
                advance()
            }
        } else {
            throw HostHookError.malformedJSON
        }
        if peek() == "." {
            advance()
            var digits = 0
            while let next = peek(), isDigit(next) {
                advance()
                digits += 1
            }
            if digits == 0 {
                throw HostHookError.malformedJSON
            }
        }
        if peek() == "e" || peek() == "E" {
            advance()
            if peek() == "+" || peek() == "-" {
                advance()
            }
            var digits = 0
            while let next = peek(), isDigit(next) {
                advance()
                digits += 1
            }
            if digits == 0 {
                throw HostHookError.malformedJSON
            }
        }
        return String(text[start..<index])
    }

    private mutating func skipBOM() {
        if text.hasPrefix("\u{FEFF}") {
            index = text.index(after: index)
        }
    }

    private mutating func skipWhitespace() {
        while let character = peek(), character == " " || character == "\n" || character == "\r" || character == "\t" {
            advance()
        }
    }

    private func peek() -> Character? {
        guard index < text.endIndex else { return nil }
        return text[index]
    }

    private mutating func advance() {
        index = text.index(after: index)
    }

    private mutating func expect(_ expected: String) throws {
        for character in expected {
            guard peek() == character else {
                throw HostHookError.malformedJSON
            }
            advance()
        }
    }

    private func hexValue(_ character: Character) -> UInt32? {
        guard let ascii = character.asciiValue else { return nil }
        switch character {
        case "0"..."9":
            return UInt32(ascii - UInt8(ascii: "0"))
        case "a"..."f":
            return UInt32(ascii - UInt8(ascii: "a") + 10)
        case "A"..."F":
            return UInt32(ascii - UInt8(ascii: "A") + 10)
        default:
            return nil
        }
    }

    private func isDigit(_ character: Character) -> Bool {
        character >= "0" && character <= "9"
    }
}

private enum HostHookJSONRenderer {
    static func write(_ value: HostHookJSON, into output: inout String, indent: Int) {
        switch value {
        case .null:
            output += "null"
        case .bool(true):
            output += "true"
        case .bool(false):
            output += "false"
        case .number(let lexeme):
            output += lexeme
        case .string(let string):
            output += escape(string)
        case .array(let items):
            if items.isEmpty {
                output += "[]"
                return
            }
            output += "[\n"
            for (offset, item) in items.enumerated() {
                output += String(repeating: "  ", count: indent + 1)
                write(item, into: &output, indent: indent + 1)
                if offset + 1 != items.count {
                    output += ","
                }
                output += "\n"
            }
            output += String(repeating: "  ", count: indent)
            output += "]"
        case .object(let members):
            if members.isEmpty {
                output += "{}"
                return
            }
            output += "{\n"
            for (offset, member) in members.enumerated() {
                output += String(repeating: "  ", count: indent + 1)
                output += escape(member.key)
                output += " : "
                write(member.value, into: &output, indent: indent + 1)
                if offset + 1 != members.count {
                    output += ","
                }
                output += "\n"
            }
            output += String(repeating: "  ", count: indent)
            output += "}"
        }
    }

    static func escape(_ string: String) -> String {
        var output = "\""
        for scalar in string.unicodeScalars {
            switch scalar {
            case "\"":
                output += "\\\""
            case "\\":
                output += "\\\\"
            case "\n":
                output += "\\n"
            case "\r":
                output += "\\r"
            case "\t":
                output += "\\t"
            case "\u{08}":
                output += "\\b"
            case "\u{0C}":
                output += "\\f"
            default:
                if scalar.value < 0x20 {
                    output += String(format: "\\u%04x", scalar.value)
                } else {
                    output.unicodeScalars.append(scalar)
                }
            }
        }
        output += "\""
        return output
    }
}
