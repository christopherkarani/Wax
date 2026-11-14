import Foundation

/// Recursive-descent parser for the subset of MIL text that `coremlc` emits for ML Programs:
/// a `program(<version>)` header, functions with typed parameters, single- or multi-output
/// operations with named arguments, typed literals (scalars, flat tensors, `BLOBFILE`
/// references) and `[name = ..., val = ...]` attribute blocks. Attribute values other than
/// `name` and `val` (build info, flexible-shape tables) are skipped, not interpreted.
struct MILParser {
    private enum Kind: Equatable {
        case identifier(String)
        case number(String)
        case string(String)
        case punctuation(UInt8)
        case arrow
        case end
    }

    private struct Token {
        var kind: Kind
        var line: Int
        var column: Int
    }

    private var tokens: [Token] = []
    private var index = 0
    private var lexError: MILRuntimeError?

    init(text: String) {
        do {
            tokens = try Self.tokenize(Array(text.utf8))
        } catch let error as MILRuntimeError {
            lexError = error
        } catch {
            lexError = .parse(line: 0, column: 0, message: "\(error)")
        }
    }

    // MARK: - Lexer

    private static func tokenize(_ bytes: [UInt8]) throws -> [Token] {
        var tokens: [Token] = []
        tokens.reserveCapacity(bytes.count / 4)
        var i = 0
        var line = 1
        var lineStart = 0
        let count = bytes.count

        func isIdentStart(_ c: UInt8) -> Bool {
            (c >= 0x41 && c <= 0x5A) || (c >= 0x61 && c <= 0x7A) || c == 0x5F
        }
        func isDigit(_ c: UInt8) -> Bool { c >= 0x30 && c <= 0x39 }
        func isIdentBody(_ c: UInt8) -> Bool { isIdentStart(c) || isDigit(c) }

        while i < count {
            let c = bytes[i]
            let column = i - lineStart + 1
            switch c {
            case 0x0A:
                line += 1
                i += 1
                lineStart = i
            case 0x20, 0x09, 0x0D:
                i += 1
            case 0x22: // string literal
                var value: [UInt8] = []
                i += 1
                var closed = false
                while i < count {
                    let d = bytes[i]
                    if d == 0x5C, i + 1 < count { // backslash escape
                        let e = bytes[i + 1]
                        switch e {
                        case 0x6E: value.append(0x0A)
                        case 0x74: value.append(0x09)
                        default: value.append(e)
                        }
                        i += 2
                        continue
                    }
                    if d == 0x22 {
                        closed = true
                        i += 1
                        break
                    }
                    if d == 0x0A {
                        break
                    }
                    value.append(d)
                    i += 1
                }
                guard closed else {
                    throw MILRuntimeError.parse(line: line, column: column, message: "unterminated string literal")
                }
                tokens.append(Token(kind: .string(String(decoding: value, as: UTF8.self)), line: line, column: column))
            case 0x2D where i + 1 < count && bytes[i + 1] == 0x3E: // ->
                tokens.append(Token(kind: .arrow, line: line, column: column))
                i += 2
            case _ where isDigit(c) || ((c == 0x2D || c == 0x2B) && i + 1 < count
                    && (isDigit(bytes[i + 1]) || bytes[i + 1] == 0x2E || bytes[i + 1] == 0x69 || bytes[i + 1] == 0x6E)):
                let start = i
                i += 1
                var hex = false
                // Detect a 0x prefix after an optional sign.
                let digitsStart = (c == 0x2D || c == 0x2B) ? start + 1 : start
                if digitsStart + 1 < count, bytes[digitsStart] == 0x30, bytes[digitsStart + 1] == 0x78 || bytes[digitsStart + 1] == 0x58 {
                    hex = true
                }
                while i < count {
                    let d = bytes[i]
                    if isIdentBody(d) || d == 0x2E {
                        i += 1
                    } else if d == 0x2B || d == 0x2D {
                        let previous = bytes[i - 1] | 0x20 // lowercase
                        if (hex && previous == 0x70) || (!hex && previous == 0x65) {
                            i += 1
                        } else {
                            break
                        }
                    } else {
                        break
                    }
                }
                let text = String(decoding: bytes[start..<i], as: UTF8.self)
                tokens.append(Token(kind: .number(text), line: line, column: column))
            case _ where isIdentStart(c):
                let start = i
                while i < count, isIdentBody(bytes[i]) { i += 1 }
                tokens.append(Token(kind: .identifier(String(decoding: bytes[start..<i], as: UTF8.self)), line: line, column: column))
            case 0x28, 0x29, 0x5B, 0x5D, 0x7B, 0x7D, 0x3C, 0x3E, 0x2C, 0x3D, 0x3F, 0x3B, 0x3A, 0x40, 0x2E:
                tokens.append(Token(kind: .punctuation(c), line: line, column: column))
                i += 1
            default:
                throw MILRuntimeError.parse(line: line, column: column, message: "unexpected character \(UnicodeScalar(c))")
            }
        }
        tokens.append(Token(kind: .end, line: line, column: count - lineStart + 1))
        return tokens
    }

    // MARK: - Token helpers

    private var current: Token { tokens[index] }

    private func peek(_ offset: Int = 0) -> Kind {
        let position = min(index + offset, tokens.count - 1)
        return tokens[position].kind
    }

    private mutating func advance() -> Token {
        let token = tokens[index]
        if index < tokens.count - 1 { index += 1 }
        return token
    }

    private func error(_ message: String) -> MILRuntimeError {
        .parse(line: current.line, column: current.column, message: message)
    }

    private func describe(_ kind: Kind) -> String {
        switch kind {
        case .identifier(let name): "identifier '\(name)'"
        case .number(let text): "number \(text)"
        case .string(let text): "string \"\(text)\""
        case .punctuation(let c): "'\(Character(UnicodeScalar(c)))'"
        case .arrow: "'->'"
        case .end: "end of input"
        }
    }

    private mutating func expect(_ c: Character) throws {
        guard case .punctuation(let p) = peek(), p == c.asciiValue else {
            throw error("expected '\(c)' but found \(describe(peek()))")
        }
        _ = advance()
    }

    private mutating func consume(_ c: Character) -> Bool {
        if case .punctuation(let p) = peek(), p == c.asciiValue {
            _ = advance()
            return true
        }
        return false
    }

    private func isPunctuation(_ c: Character, at offset: Int = 0) -> Bool {
        if case .punctuation(let p) = peek(offset), p == c.asciiValue { return true }
        return false
    }

    private mutating func identifier() throws -> String {
        guard case .identifier(let name) = peek() else {
            throw error("expected an identifier but found \(describe(peek()))")
        }
        _ = advance()
        return name
    }

    private mutating func keyword(_ word: String) throws {
        guard case .identifier(let name) = peek(), name == word else {
            throw error("expected '\(word)' but found \(describe(peek()))")
        }
        _ = advance()
    }

    // MARK: - Grammar

    mutating func parseProgram() throws -> MILProgram {
        if let lexError { throw lexError }
        try keyword("program")
        try expect("(")
        guard case .number(let version) = peek() else {
            throw error("expected a program version")
        }
        _ = advance()
        try expect(")")
        if isPunctuation("[") { try skipAttributes() }
        try expect("{")
        var functions: [String: MILFunction] = [:]
        while case .identifier("func") = peek() {
            let function = try parseFunction()
            functions[function.name] = function
        }
        try expect("}")
        guard case .end = peek() else {
            throw error("unexpected \(describe(peek())) after the program")
        }
        return MILProgram(version: version, functions: functions)
    }

    private mutating func parseFunction() throws -> MILFunction {
        try keyword("func")
        let name = try identifier()
        var opset: String?
        if consume("<") {
            opset = try identifier()
            try expect(">")
        }
        try expect("(")
        var inputs: [MILNamedType] = []
        if !isPunctuation(")") {
            repeat {
                let type = try parseType()
                inputs.append(MILNamedType(name: try identifier(), type: type))
            } while consume(",")
        }
        try expect(")")
        if isPunctuation("[") { try skipAttributes() }
        try expect("{")
        var operations: [MILOperation] = []
        while !isPunctuation("}") {
            operations.append(try parseOperation())
        }
        try expect("}")
        guard case .arrow = peek() else {
            throw error("expected '->' after the body of function \(name)")
        }
        _ = advance()
        try expect("(")
        var outputs: [String] = []
        if !isPunctuation(")") {
            repeat { outputs.append(try identifier()) } while consume(",")
        }
        try expect(")")
        try expect(";")
        return MILFunction(name: name, opset: opset, inputs: inputs, operations: operations, outputs: outputs)
    }

    private mutating func parseType() throws -> MILType {
        let name = try identifier()
        if name == "tensor" {
            try expect("<")
            let dataType = try dataType(named: try identifier())
            try expect(",")
            try expect("[")
            var dims: [MILDimension] = []
            if !isPunctuation("]") {
                repeat {
                    switch peek() {
                    case .number(let text):
                        guard let value = Int(text), value >= 0 else { throw error("invalid dimension \(text)") }
                        dims.append(.fixed(value))
                        _ = advance()
                    case .punctuation(UInt8(ascii: "?")):
                        dims.append(.unknown)
                        _ = advance()
                    case .identifier:
                        // Symbolic dimension such as `is0`.
                        dims.append(.unknown)
                        _ = advance()
                    default:
                        throw error("expected a dimension but found \(describe(peek()))")
                    }
                } while consume(",")
            }
            try expect("]")
            try expect(">")
            return .tensor(dataType, dims)
        }
        return .scalar(try dataType(named: name))
    }

    private func dataType(named name: String) throws -> MILDataType {
        guard let type = MILDataType(rawValue: name) else {
            throw error("unsupported type \(name)")
        }
        return type
    }

    private mutating func parseOperation() throws -> MILOperation {
        let line = current.line
        var outputs: [MILNamedType] = []
        if consume("(") {
            repeat {
                let type = try parseType()
                outputs.append(MILNamedType(name: try identifier(), type: type))
            } while consume(",")
            try expect(")")
        } else {
            let type = try parseType()
            outputs.append(MILNamedType(name: try identifier(), type: type))
        }
        try expect("=")
        let opType = try identifier()
        try expect("(")
        var arguments: [String: MILArgument] = [:]
        if !isPunctuation(")") {
            repeat {
                let key = try identifier()
                try expect("=")
                arguments[key] = try parseArgument()
            } while consume(",")
        }
        try expect(")")
        var name: String?
        var value: MILLiteral?
        if consume("[") {
            if !isPunctuation("]") {
                repeat {
                    let key = try identifier()
                    try expect("=")
                    switch key {
                    case "name":
                        guard case .string(let text) = try parseLiteral() else {
                            throw error("an operation name must be a string")
                        }
                        name = text
                    case "val":
                        value = try parseLiteral()
                    default:
                        try skipValue()
                    }
                } while consume(",")
            }
            try expect("]")
        }
        try expect(";")
        return MILOperation(opType: opType, outputs: outputs, arguments: arguments, name: name, value: value, line: line)
    }

    private mutating func parseArgument() throws -> MILArgument {
        if consume("(") {
            var items: [MILArgument] = []
            if !isPunctuation(")") {
                repeat { items.append(try parseArgument()) } while consume(",")
            }
            try expect(")")
            return .tuple(items)
        }
        guard case .identifier(let name) = peek() else {
            throw error("expected an argument value but found \(describe(peek()))")
        }
        let isTensorLiteral = name == "tensor" && isPunctuation("<", at: 1)
        let isScalarLiteral = MILDataType(rawValue: name) != nil && isPunctuation("(", at: 1)
        if isTensorLiteral || isScalarLiteral {
            return .literal(try parseLiteral())
        }
        _ = advance()
        return .variable(name)
    }

    /// `<type>(<body>)`: a scalar, a string, a flat (or nested) tensor list, or a BLOBFILE.
    private mutating func parseLiteral() throws -> MILLiteral {
        let type = try parseType()
        try expect("(")
        let literal: MILLiteral
        switch type {
        case .scalar(.string):
            guard case .string(let text) = peek() else { throw error("expected a string literal") }
            _ = advance()
            literal = .string(text)
        case .scalar(let dataType):
            literal = .tensor(dataType: dataType, shape: [], values: [try parseNumber(as: dataType)])
        case .tensor(let dataType, let dims):
            var shape: [Int] = []
            for dim in dims {
                guard case .fixed(let value) = dim else { throw error("a tensor literal needs a fixed shape") }
                shape.append(value)
            }
            if case .identifier("BLOBFILE") = peek() {
                _ = advance()
                try expect("(")
                var path: String?
                var offset: UInt64?
                repeat {
                    let key = try identifier()
                    try expect("=")
                    switch key {
                    case "path":
                        guard case .string(let text) = try parseLiteral() else { throw error("BLOBFILE path must be a string") }
                        path = text
                    case "offset":
                        let typeName = try identifier()
                        try expect("(")
                        guard typeName.hasPrefix("uint") || typeName.hasPrefix("int"),
                              case .number(let text) = peek(), let value = UInt64(text)
                        else { throw error("BLOBFILE offset must be an unsigned integer") }
                        _ = advance()
                        try expect(")")
                        offset = value
                    default:
                        try skipValue()
                    }
                } while consume(",")
                try expect(")")
                guard let path, let offset else { throw error("BLOBFILE needs a path and an offset") }
                literal = .blob(dataType: dataType, shape: shape, path: path, offset: offset)
            } else {
                var values: [Double] = []
                values.reserveCapacity(shape.reduce(1, *))
                try parseList(into: &values, dataType: dataType)
                let expected = shape.reduce(1, *)
                guard values.count == expected else {
                    throw error("tensor literal has \(values.count) values but its shape \(shape) needs \(expected)")
                }
                literal = .tensor(dataType: dataType, shape: shape, values: values)
            }
        }
        try expect(")")
        return literal
    }

    private mutating func parseList(into values: inout [Double], dataType: MILDataType) throws {
        try expect("[")
        if !isPunctuation("]") {
            repeat {
                if isPunctuation("[") {
                    try parseList(into: &values, dataType: dataType)
                } else {
                    values.append(try parseNumber(as: dataType))
                }
            } while consume(",")
        }
        try expect("]")
    }

    private mutating func parseNumber(as dataType: MILDataType) throws -> Double {
        let token = peek()
        let text: String
        switch token {
        case .number(let value): text = value
        case .identifier(let value): text = value
        default: throw error("expected a \(dataType.rawValue) value but found \(describe(token))")
        }
        let value: Double?
        switch dataType {
        case .bool:
            value = text == "true" ? 1 : (text == "false" ? 0 : nil)
        case .fp32:
            value = Float(text).map(Double.init)
        case .fp16:
            value = Double(text)
        case .string:
            value = nil
        default:
            value = Int64(text).map(Double.init)
        }
        guard let value else {
            throw error("invalid \(dataType.rawValue) literal \(text)")
        }
        _ = advance()
        return value
    }

    /// Skips one attribute value, stopping before a top-level ',' or ']'.
    private mutating func skipValue() throws {
        var depth = 0
        while true {
            switch peek() {
            case .end:
                throw error("unterminated attribute value")
            case .punctuation(let c):
                switch c {
                case UInt8(ascii: "("), UInt8(ascii: "["), UInt8(ascii: "{"), UInt8(ascii: "<"):
                    depth += 1
                case UInt8(ascii: ")"), UInt8(ascii: "]"), UInt8(ascii: "}"), UInt8(ascii: ">"):
                    if depth == 0 { return }
                    depth -= 1
                case UInt8(ascii: ","):
                    if depth == 0 { return }
                default:
                    break
                }
            default:
                break
            }
            _ = advance()
        }
    }

    private mutating func skipAttributes() throws {
        try expect("[")
        if !isPunctuation("]") {
            repeat {
                _ = try identifier()
                try expect("=")
                try skipValue()
            } while consume(",")
        }
        try expect("]")
    }
}
