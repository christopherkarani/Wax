import Foundation

/// Element types that appear in MIL text and in MIL blob files.
package enum MILDataType: String, Sendable, Hashable, CaseIterable {
    case fp16
    case fp32
    case int8
    case uint8
    case int16
    case uint16
    case int32
    case uint32
    case bool
    case string

    package var isFloatingPoint: Bool { self == .fp16 || self == .fp32 }

    /// Floating-point tensors are held and computed in Float32 whatever their declared width.
    /// 8-bit integers (quantised weight payloads) are widened to Float32 too; every other
    /// integer type and bool is held as Int32.
    package var usesFloatStorage: Bool { self == .fp16 || self == .fp32 || self == .int8 || self == .uint8 }
}

package enum MILDimension: Sendable, Hashable {
    case fixed(Int)
    case unknown
}

package enum MILType: Sendable, Hashable {
    case tensor(MILDataType, [MILDimension])
    case scalar(MILDataType)

    package var dataType: MILDataType {
        switch self {
        case .tensor(let dataType, _), .scalar(let dataType): dataType
        }
    }

    /// Declared dimensions; a scalar has rank 0.
    package var dimensions: [MILDimension] {
        switch self {
        case .tensor(_, let dims): dims
        case .scalar: []
        }
    }
}

package struct MILNamedType: Sendable, Hashable {
    package var name: String
    package var type: MILType

    package init(name: String, type: MILType) {
        self.name = name
        self.type = type
    }
}

/// A literal value in program text. Numbers of every element type are held as `Double`, which
/// represents all fp16, fp32, int32 and bool values exactly.
package enum MILLiteral: Sendable, Hashable {
    case string(String)
    case tensor(dataType: MILDataType, shape: [Int], values: [Double])
    case blob(dataType: MILDataType, shape: [Int], path: String, offset: UInt64)
}

package indirect enum MILArgument: Sendable, Hashable {
    case variable(String)
    case literal(MILLiteral)
    case tuple([MILArgument])
}

package struct MILOperation: Sendable, Hashable {
    package var opType: String
    package var outputs: [MILNamedType]
    package var arguments: [String: MILArgument]
    /// The `name` attribute, when present.
    package var name: String?
    /// The `val` attribute of a `const` operation.
    package var value: MILLiteral?
    /// 1-based line in the program text, for error messages.
    package var line: Int
}

package struct MILFunction: Sendable, Hashable {
    package var name: String
    package var opset: String?
    package var inputs: [MILNamedType]
    package var operations: [MILOperation]
    package var outputs: [String]
}

package struct MILProgram: Sendable, Hashable {
    package var version: String
    package var functions: [String: MILFunction]

    /// Parses the MIL text form that `coremlc` writes to `model.mil`.
    package init(parsing text: String) throws {
        var parser = MILParser(text: text)
        self = try parser.parseProgram()
    }

    package init(version: String, functions: [String: MILFunction]) {
        self.version = version
        self.functions = functions
    }
}

package enum MILRuntimeError: Error, Sendable, Equatable, CustomStringConvertible {
    case parse(line: Int, column: Int, message: String)
    case blob(String)
    case missingFunction(String)
    case unsupportedOperation(op: String, line: Int)
    case invalidArgument(op: String, line: Int, message: String)
    case undefinedVariable(name: String, line: Int)
    case missingInput(String)
    case unexpectedInput(String)
    case inputMismatch(name: String, message: String)
    case outputMismatch(op: String, line: Int, message: String)

    package var description: String {
        switch self {
        case .parse(let line, let column, let message):
            "MIL parse error at \(line):\(column): \(message)"
        case .blob(let message):
            "MIL weight blob error: \(message)"
        case .missingFunction(let name):
            "MIL program has no function named \(name)"
        case .unsupportedOperation(let op, let line):
            "MIL operation \(op) (line \(line)) is not supported"
        case .invalidArgument(let op, let line, let message):
            "MIL \(op) (line \(line)): \(message)"
        case .undefinedVariable(let name, let line):
            "MIL variable \(name) used at line \(line) is not defined"
        case .missingInput(let name):
            "MIL input \(name) was not provided"
        case .unexpectedInput(let name):
            "MIL function has no input named \(name)"
        case .inputMismatch(let name, let message):
            "MIL input \(name): \(message)"
        case .outputMismatch(let op, let line, let message):
            "MIL \(op) (line \(line)) produced a value that does not match its declared type: \(message)"
        }
    }
}
