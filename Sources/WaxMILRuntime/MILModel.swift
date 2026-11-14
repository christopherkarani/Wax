import Foundation

/// A value bound to a MIL variable while a function runs.
package enum MILValue: Sendable {
    case tensor(MILTensor)
    case string(String)
    case list([MILValue])
}

/// Named output tensor of a model run, as Float32 values in row-major order.
package struct MILOutput: Sendable, Equatable {
    package let shape: [Int]
    package let values: [Float]

    package init(shape: [Int], values: [Float]) {
        self.shape = shape
        self.values = values
    }
}

/// A compiled Core ML ML Program (`.mlmodelc` directory with `model.mil` and
/// `weights/weight.bin`), executed by a Float32 CPU interpreter without Core ML.
///
/// Loading parses the program, maps the weight file, materialises every `const`, dequantises
/// `constexpr_*` weights once, folds operations whose inputs are all constant and packs constant
/// `linear` weights for the GEMM kernel. The result is immutable: `predict` keeps all per-run
/// state local, so one model can serve concurrent calls.
package final class MILModel: Sendable {
    package let functionName: String
    package let inputs: [MILNamedType]
    package let outputNames: [String]
    /// Upper bound on threads one `predict` call uses for large matrix products.
    package let maximumThreads: Int

    /// The default for `maximumThreads`: the active processor count, capped at 8.
    package static var defaultMaximumThreads: Int {
        min(max(ProcessInfo.processInfo.activeProcessorCount, 1), 8)
    }

    private let instructions: [Instruction]
    private let slotCount: Int
    private let inputSlots: [Int]
    private let outputSources: [Operand]

    /// Loads `model.mil` (and its weight files) from a compiled `.mlmodelc` directory.
    package convenience init(contentsOf modelDirectory: URL, function: String = "main", maximumThreads: Int? = nil) throws {
        let programURL = modelDirectory.appendingPathComponent("model.mil")
        let text: String
        do {
            text = try String(contentsOf: programURL, encoding: .utf8)
        } catch {
            throw MILRuntimeError.blob("cannot read \(programURL.path): \(error)")
        }
        try self.init(programText: text, modelDirectory: modelDirectory, function: function, maximumThreads: maximumThreads)
    }

    /// Compiles MIL text. `modelDirectory` resolves `@model_path` in `BLOBFILE` paths.
    package convenience init(
        programText: String,
        modelDirectory: URL? = nil,
        function: String = "main",
        maximumThreads: Int? = nil
    ) throws {
        try self.init(
            program: MILProgram(parsing: programText),
            modelDirectory: modelDirectory,
            function: function,
            maximumThreads: maximumThreads
        )
    }

    package init(
        program: MILProgram,
        modelDirectory: URL? = nil,
        function: String = "main",
        maximumThreads: Int? = nil
    ) throws {
        guard let main = program.functions[function] else {
            throw MILRuntimeError.missingFunction(function)
        }
        var compiler = MILCompiler(modelDirectory: modelDirectory)
        let compiled = try compiler.compile(main)
        functionName = function
        self.maximumThreads = max(1, maximumThreads ?? Self.defaultMaximumThreads)
        inputs = main.inputs
        outputNames = main.outputs
        instructions = compiled.instructions
        slotCount = compiled.slotCount
        inputSlots = compiled.inputSlots
        outputSources = compiled.outputs
    }

    /// Runs the function on named input tensors and returns every declared output.
    package func predict(_ feeds: [String: MILTensor]) throws -> [String: MILTensor] {
        for name in feeds.keys where !inputs.contains(where: { $0.name == name }) {
            throw MILRuntimeError.unexpectedInput(name)
        }
        var slots = [MILValue?](repeating: nil, count: slotCount)
        for (input, slot) in zip(inputs, inputSlots) {
            guard let tensor = feeds[input.name] else {
                throw MILRuntimeError.missingInput(input.name)
            }
            try Self.validate(tensor, against: input)
            slots[slot] = .tensor(tensor.retyped(input.type.dataType))
        }
        for instruction in instructions {
            let arguments = try MILArguments(instruction: instruction, slots: slots)
            let result = try MILKernels.run(instruction, arguments, threads: maximumThreads)
            slots[instruction.outputSlot] = .tensor(try instruction.conform(result))
            for slot in instruction.releases {
                slots[slot] = nil
            }
        }
        var outputs: [String: MILTensor] = [:]
        for (name, source) in zip(outputNames, outputSources) {
            guard case .tensor(let tensor) = try source.resolve(slots, op: "output", line: 0) else {
                throw MILRuntimeError.invalidArgument(op: "output", line: 0, message: "\(name) is not a tensor")
            }
            outputs[name] = tensor
        }
        return outputs
    }

    /// Runs a BERT-style encoder on `[batch][sequence]` token ids. `tokenTypeIDs` defaults to
    /// zeros when the function takes `token_type_ids`; it must be nil when it does not.
    package func predict(
        inputIDs: [[Int32]],
        attentionMask: [[Int32]],
        tokenTypeIDs: [[Int32]]? = nil
    ) throws -> [String: MILOutput] {
        let batch = inputIDs.count
        let sequence = inputIDs.first?.count ?? 0
        guard batch > 0, sequence > 0 else {
            throw MILRuntimeError.inputMismatch(name: "input_ids", message: "needs at least one non-empty row")
        }
        func flatten(_ rows: [[Int32]], _ name: String) throws -> [Int32] {
            guard rows.count == batch, rows.allSatisfy({ $0.count == sequence }) else {
                throw MILRuntimeError.inputMismatch(name: name, message: "every row must have \(sequence) tokens and there must be \(batch) rows")
            }
            return rows.flatMap { $0 }
        }
        return try predict(
            inputIDs: flatten(inputIDs, "input_ids"),
            attentionMask: flatten(attentionMask, "attention_mask"),
            shape: [batch, sequence],
            tokenTypeIDs: tokenTypeIDs.map { try flatten($0, "token_type_ids") }
        )
    }

    /// Flat row-major variant of `predict(inputIDs:attentionMask:tokenTypeIDs:)`.
    package func predict(
        inputIDs: [Int32],
        attentionMask: [Int32],
        shape: [Int],
        tokenTypeIDs: [Int32]? = nil
    ) throws -> [String: MILOutput] {
        let count = shape.reduce(1, *)
        var feeds: [String: MILTensor] = [:]
        func add(_ name: String, _ values: [Int32]) throws {
            guard values.count == count else {
                throw MILRuntimeError.inputMismatch(name: name, message: "has \(values.count) values for shape \(shape)")
            }
            feeds[name] = MILTensor(int32: values, shape: shape)
        }
        try add("input_ids", inputIDs)
        try add("attention_mask", attentionMask)
        if inputs.contains(where: { $0.name == "token_type_ids" }) {
            try add("token_type_ids", tokenTypeIDs ?? [Int32](repeating: 0, count: count))
        } else if tokenTypeIDs != nil {
            throw MILRuntimeError.unexpectedInput("token_type_ids")
        }
        return try predict(feeds).mapValues { MILOutput(shape: $0.shape, values: $0.floats) }
    }

    private static func validate(_ tensor: MILTensor, against input: MILNamedType) throws {
        let dims = input.type.dimensions
        guard tensor.rank == dims.count else {
            throw MILRuntimeError.inputMismatch(name: input.name, message: "rank \(tensor.rank), expected \(dims.count)")
        }
        for (actual, declared) in zip(tensor.shape, dims) {
            if case .fixed(let size) = declared, size != actual {
                throw MILRuntimeError.inputMismatch(name: input.name, message: "shape \(tensor.shape) does not match \(dims)")
            }
        }
        guard tensor.hasFloatStorage == input.type.dataType.usesFloatStorage else {
            throw MILRuntimeError.inputMismatch(name: input.name, message: "expected \(input.type.dataType.rawValue) values")
        }
    }
}

// MARK: - Compilation

indirect enum Operand: Sendable {
    case slot(Int, name: String)
    case value(MILValue)
    case list([Operand])

    func resolve(_ slots: [MILValue?], op: String, line: Int) throws -> MILValue {
        switch self {
        case .value(let value):
            return value
        case .slot(let index, let name):
            guard let value = slots[index] else {
                throw MILRuntimeError.undefinedVariable(name: name, line: line)
            }
            return value
        case .list(let items):
            return .list(try items.map { try $0.resolve(slots, op: op, line: line) })
        }
    }

    var isConstant: Bool {
        switch self {
        case .value: true
        case .slot: false
        case .list(let items): items.allSatisfy(\.isConstant)
        }
    }

    func forEachSlot(_ body: (Int) -> Void) {
        switch self {
        case .value: break
        case .slot(let index, _): body(index)
        case .list(let items): items.forEach { $0.forEachSlot(body) }
        }
    }
}

struct Instruction: Sendable {
    let kind: MILOpKind
    let opType: String
    let line: Int
    let operands: [String: Operand]
    let outputSlot: Int
    let declared: MILType
    var releases: [Int] = []
    /// A constant `linear` weight, pre-packed; its `weight` operand is then dropped.
    var packedWeight: MILPackedMatrix?

    func conform(_ tensor: MILTensor) throws -> MILTensor {
        try WaxMILRuntime.conform(tensor, to: declared, opType: opType, line: line)
    }
}

/// Tags `tensor` with the declared element type and checks its rank and fixed dimensions.
func conform(_ tensor: MILTensor, to declared: MILType, opType: String, line: Int) throws -> MILTensor {
    let dims = declared.dimensions
    guard tensor.rank == dims.count else {
        throw MILRuntimeError.outputMismatch(op: opType, line: line, message: "rank \(tensor.rank) (shape \(tensor.shape)), declared \(dims.count)")
    }
    for (actual, dim) in zip(tensor.shape, dims) {
        if case .fixed(let size) = dim, size != actual {
            throw MILRuntimeError.outputMismatch(op: opType, line: line, message: "shape \(tensor.shape), declared \(dims)")
        }
    }
    let dataType = declared.dataType
    guard tensor.hasFloatStorage == dataType.usesFloatStorage else {
        throw MILRuntimeError.outputMismatch(op: opType, line: line, message: "\(tensor.dataType.rawValue) values, declared \(dataType.rawValue)")
    }
    return tensor.retyped(dataType)
}

private struct MILCompiler {
    struct Output {
        var instructions: [Instruction]
        var slotCount: Int
        var inputSlots: [Int]
        var outputs: [Operand]
    }

    let modelDirectory: URL?
    private var weightFiles: [String: MILWeightFile] = [:]
    private var bindings: [String: Operand] = [:]
    private var slotCount = 0

    init(modelDirectory: URL?) {
        self.modelDirectory = modelDirectory
    }

    mutating func compile(_ function: MILFunction) throws -> Output {
        var inputSlots: [Int] = []
        for input in function.inputs {
            let slot = newSlot()
            bindings[input.name] = .slot(slot, name: input.name)
            inputSlots.append(slot)
        }
        var instructions: [Instruction] = []
        for op in function.operations {
            guard op.outputs.count == 1, let output = op.outputs.first else {
                throw MILRuntimeError.unsupportedOperation(op: "\(op.opType) with \(op.outputs.count) outputs", line: op.line)
            }
            if op.opType == "const" {
                guard let literal = op.value else {
                    throw MILRuntimeError.invalidArgument(op: "const", line: op.line, message: "missing val")
                }
                let value = try materialize(literal, op: op)
                if case .tensor(let tensor) = value {
                    let conformed = try conform(tensor, to: output.type, opType: "const", line: op.line)
                    bindings[output.name] = .value(.tensor(conformed))
                } else {
                    bindings[output.name] = .value(value)
                }
                continue
            }
            guard let kind = MILOpKind(rawValue: op.opType) else {
                throw MILRuntimeError.unsupportedOperation(op: op.opType, line: op.line)
            }
            var operands: [String: Operand] = [:]
            for (key, argument) in op.arguments {
                operands[key] = try operand(argument, op: op)
            }
            if operands.values.allSatisfy(\.isConstant) {
                // Constant folding: constexpr_* dequantisation and any input-independent op.
                let instruction = Instruction(kind: kind, opType: op.opType, line: op.line, operands: operands, outputSlot: -1, declared: output.type)
                let arguments = try MILArguments(instruction: instruction, slots: [])
                let folded = try instruction.conform(MILKernels.run(instruction, arguments, threads: 1))
                bindings[output.name] = .value(.tensor(folded))
                continue
            }
            var packedWeight: MILPackedMatrix?
            if kind == .linear, case .value(.tensor(let weight))? = operands["weight"], weight.rank == 2 {
                // Pack once; dropping the operand lets the unpacked copy be freed.
                packedWeight = MILPackedMatrix(weight: weight)
                operands["weight"] = nil
            }
            let slot = newSlot()
            var instruction = Instruction(kind: kind, opType: op.opType, line: op.line, operands: operands, outputSlot: slot, declared: output.type)
            instruction.packedWeight = packedWeight
            bindings[output.name] = .slot(slot, name: output.name)
            instructions.append(instruction)
        }
        var outputs: [Operand] = []
        for name in function.outputs {
            guard let binding = bindings[name] else {
                throw MILRuntimeError.undefinedVariable(name: name, line: 0)
            }
            outputs.append(binding)
        }
        // Free each intermediate after its last use; never free function outputs.
        var pinned = Set<Int>()
        outputs.forEach { $0.forEachSlot { pinned.insert($0) } }
        var lastUse: [Int: Int] = [:]
        for (index, instruction) in instructions.enumerated() {
            for operand in instruction.operands.values {
                operand.forEachSlot { lastUse[$0] = index }
            }
        }
        for (slot, index) in lastUse where !pinned.contains(slot) {
            instructions[index].releases.append(slot)
        }
        return Output(instructions: instructions, slotCount: slotCount, inputSlots: inputSlots, outputs: outputs)
    }

    private mutating func newSlot() -> Int {
        defer { slotCount += 1 }
        return slotCount
    }

    private mutating func operand(_ argument: MILArgument, op: MILOperation) throws -> Operand {
        switch argument {
        case .variable(let name):
            guard let binding = bindings[name] else {
                throw MILRuntimeError.undefinedVariable(name: name, line: op.line)
            }
            return binding
        case .literal(let literal):
            return .value(try materialize(literal, op: op))
        case .tuple(let items):
            return .list(try items.map { try operand($0, op: op) })
        }
    }

    private mutating func materialize(_ literal: MILLiteral, op: MILOperation) throws -> MILValue {
        switch literal {
        case .string(let text):
            return .string(text)
        case .tensor(let dataType, let shape, let values):
            if dataType.usesFloatStorage {
                return .tensor(MILTensor(dataType: dataType, shape: shape, storage: .float(MILFloatStorage(values.map { Float($0) }))))
            }
            return .tensor(MILTensor(dataType: dataType, shape: shape, storage: .int(values.map { Int32(clamping: Int64($0)) })))
        case .blob(let dataType, let shape, let path, let offset):
            return .tensor(try weightFile(path, op: op).tensor(at: offset, dataType: dataType, shape: shape))
        }
    }

    private mutating func weightFile(_ path: String, op: MILOperation) throws -> MILWeightFile {
        if let file = weightFiles[path] { return file }
        let prefix = "@model_path/"
        guard path.hasPrefix(prefix), let modelDirectory else {
            throw MILRuntimeError.invalidArgument(op: op.opType, line: op.line, message: "cannot resolve BLOBFILE path \(path) without a model directory")
        }
        let url = modelDirectory.appendingPathComponent(String(path.dropFirst(prefix.count)))
        let file = try MILWeightFile(contentsOf: url)
        weightFiles[path] = file
        return file
    }
}
