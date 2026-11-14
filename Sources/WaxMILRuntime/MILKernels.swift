import Foundation
import WaxMILKernelsC

/// Op semantics follow the coremltools MIL op reference (iOS 15–18 opsets). Floating-point
/// work is Float32; integer work is Int32 with the declared narrow type applied by `cast`.
enum MILKernels {
    static func run(_ instruction: Instruction, _ args: MILArguments, threads: Int) throws -> MILTensor {
        switch instruction.kind {
        case .add: return try binary(.add, args)
        case .sub: return try binary(.sub, args)
        case .mul: return try binary(.mul, args)
        case .realDiv: return try binary(.div, args)
        case .equal: return try binary(.equal, args)
        case .notEqual: return try binary(.notEqual, args)
        case .greater: return try binary(.greater, args)
        case .greaterEqual: return try binary(.greaterEqual, args)
        case .less: return try binary(.less, args)
        case .lessEqual: return try binary(.lessEqual, args)
        case .select: return try select(args)
        case .cast: return try cast(args)
        case .clip: return try clip(args)
        case .concat: return try concat(args)
        case .constexprBlockwiseShiftScale: return try blockwiseShiftScale(args)
        case .expandDims: return try expandDims(args)
        case .gather: return try gather(args)
        case .gelu: return try gelu(args, threads: threads)
        case .layerNorm: return try layerNorm(args, threads: threads)
        case .linear: return try linear(args, packed: instruction.packedWeight, threads: threads)
        case .matmul: return try matmul(args, threads: threads)
        case .reduceL2Norm: return try reduce(args, squared: true)
        case .reduceSum: return try reduce(args, squared: false)
        case .reshape: return try reshape(args)
        case .shape: return try shape(args)
        case .sliceByIndex: return try sliceByIndex(args)
        case .softmax: return try softmax(args, threads: threads)
        case .tanh: return try tanh(args)
        case .tile: return try tile(args)
        case .transpose: return try transpose(args)
        }
    }

    // MARK: - Helpers

    static func contiguousStrides(_ shape: [Int]) -> [Int] {
        var strides = [Int](repeating: 1, count: shape.count)
        var running = 1
        for d in stride(from: shape.count - 1, through: 0, by: -1) {
            strides[d] = running
            running *= shape[d]
        }
        return strides
    }

    static func makeFloat(_ shape: [Int], _ fill: (UnsafeMutableBufferPointer<Float>) throws -> Void) rethrows -> MILTensor {
        let count = shape.reduce(1, *)
        return MILTensor(dataType: .fp32, shape: shape, storage: .float(try MILFloatStorage.make(count: count, fill)))
    }

    static func floatStorage(_ tensor: MILTensor) -> MILFloatStorage {
        switch tensor.storage {
        case .float(let storage): storage
        case .int(let values): MILFloatStorage(values.map { Float($0) })
        }
    }

    /// Float-to-integer conversion that truncates toward zero and saturates instead of trapping.
    static func truncatingToInt32(_ value: Float) -> Int32 {
        guard value.isFinite else { return value.isNaN ? 0 : (value > 0 ? .max : .min) }
        let truncated = value.rounded(.towardZero)
        if truncated >= 2_147_483_648 { return .max }
        if truncated <= -2_147_483_648 { return .min }
        return Int32(truncated)
    }

    static func broadcastShape(_ a: [Int], _ b: [Int], _ args: MILArguments) throws -> [Int] {
        let rank = max(a.count, b.count)
        var out = [Int](repeating: 1, count: rank)
        for i in 0..<rank {
            let da = i < rank - a.count ? 1 : a[i - (rank - a.count)]
            let db = i < rank - b.count ? 1 : b[i - (rank - b.count)]
            guard da == db || da == 1 || db == 1 else {
                throw args.failure("shapes \(a) and \(b) do not broadcast")
            }
            out[i] = da == 1 ? db : da
        }
        return out
    }

    /// Element strides of `shape` viewed in `outShape` (left-padded), 0 on broadcast axes.
    static func broadcastStrides(_ shape: [Int], to outShape: [Int]) -> [Int] {
        let padded = [Int](repeating: 1, count: outShape.count - shape.count) + shape
        var strides = contiguousStrides(padded)
        for d in 0..<outShape.count where padded[d] == 1 && outShape[d] != 1 {
            strides[d] = 0
        }
        return strides
    }

    /// For each output element, the linear offset of the corresponding input element.
    static func broadcastOffsets(_ shape: [Int], to outShape: [Int]) -> [Int] {
        let strides = broadcastStrides(shape, to: outShape)
        let count = outShape.reduce(1, *)
        var offsets = [Int](repeating: 0, count: count)
        guard count > 0 else { return offsets }
        var index = [Int](repeating: 0, count: outShape.count)
        var offset = 0
        for linear in 0..<count {
            offsets[linear] = offset
            var d = outShape.count - 1
            while d >= 0 {
                index[d] += 1
                offset += strides[d]
                if index[d] < outShape[d] { break }
                offset -= strides[d] * index[d]
                index[d] = 0
                d -= 1
            }
        }
        return offsets
    }

    /// Visits the output's rows (its last axis), passing the row length and each input's
    /// starting offset and stride (0 or 1) along that row.
    static func forEachBroadcastRow(
        outShape: [Int],
        xStrides: [Int],
        yStrides: [Int],
        _ body: (_ length: Int, _ out: Int, _ x: Int, _ sx: Int, _ y: Int, _ sy: Int) -> Void
    ) {
        let rank = outShape.count
        guard rank > 0 else {
            body(1, 0, 0, 0, 0, 0)
            return
        }
        let length = outShape[rank - 1]
        let rows = outShape.reduce(1, *) / max(length, 1)
        guard length > 0 else { return }
        var index = [Int](repeating: 0, count: rank - 1)
        for row in 0..<rows {
            var xo = 0
            var yo = 0
            for d in 0..<(rank - 1) {
                xo += index[d] * xStrides[d]
                yo += index[d] * yStrides[d]
            }
            body(length, row * length, xo, xStrides[rank - 1], yo, yStrides[rank - 1])
            var d = rank - 2
            while d >= 0 {
                index[d] += 1
                if index[d] < outShape[d] { break }
                index[d] = 0
                d -= 1
            }
        }
    }

    // MARK: - Elementwise

    enum BinaryOp {
        case add, sub, mul, div
        case equal, notEqual, greater, greaterEqual, less, lessEqual

        var isComparison: Bool {
            switch self {
            case .add, .sub, .mul, .div: false
            default: true
            }
        }
    }

    @inline(__always)
    private static func row(
        _ n: Int, _ o: UnsafeMutablePointer<Float>,
        _ x: UnsafePointer<Float>, _ sx: Int,
        _ y: UnsafePointer<Float>, _ sy: Int,
        _ f: (Float, Float) -> Float
    ) {
        if sx == 1, sy == 1 {
            for i in 0..<n { o[i] = f(x[i], y[i]) }
        } else if sx == 1 {
            let b = y[0]
            for i in 0..<n { o[i] = f(x[i], b) }
        } else if sy == 1 {
            let a = x[0]
            for i in 0..<n { o[i] = f(a, y[i]) }
        } else {
            let v = f(x[0], y[0])
            for i in 0..<n { o[i] = v }
        }
    }

    static func binary(_ op: BinaryOp, _ args: MILArguments) throws -> MILTensor {
        let x = try args.tensor("x")
        let y = try args.tensor("y")
        let outShape = try broadcastShape(x.shape, y.shape, args)
        let count = outShape.reduce(1, *)

        if op.isComparison || !(x.hasFloatStorage || y.hasFloatStorage) {
            // Integer arithmetic and all comparisons: small tensors (shapes, ids, masks).
            let xo = broadcastOffsets(x.shape, to: outShape)
            let yo = broadcastOffsets(y.shape, to: outShape)
            if x.hasFloatStorage || y.hasFloatStorage {
                let xv = x.floats
                let yv = y.floats
                var out = [Int32](repeating: 0, count: count)
                for i in 0..<count {
                    out[i] = compare(op, xv[xo[i]], yv[yo[i]]) ? 1 : 0
                }
                return MILTensor(dataType: .bool, shape: outShape, storage: .int(out))
            }
            let xv = x.int32s
            let yv = y.int32s
            var out = [Int32](repeating: 0, count: count)
            for i in 0..<count {
                let a = xv[xo[i]]
                let b = yv[yo[i]]
                switch op {
                case .add: out[i] = a &+ b
                case .sub: out[i] = a &- b
                case .mul: out[i] = a &* b
                case .div:
                    guard b != 0 else { throw args.failure("integer division by zero") }
                    out[i] = truncatingToInt32(Float(a) / Float(b))
                default: out[i] = compare(op, Float(a), Float(b)) ? 1 : 0
                }
            }
            return MILTensor(dataType: op.isComparison ? .bool : .int32, shape: outShape, storage: .int(out))
        }

        let xs = floatStorage(x)
        let ys = floatStorage(y)
        let xStrides = broadcastStrides(x.shape, to: outShape)
        let yStrides = broadcastStrides(y.shape, to: outShape)
        return xs.withUnsafeBufferPointer { xb in
            ys.withUnsafeBufferPointer { yb in
                makeFloat(outShape) { out in
                    guard let o = out.baseAddress, let xp = xb.baseAddress, let yp = yb.baseAddress else { return }
                    func apply(_ n: Int, _ oo: Int, _ xo: Int, _ sx: Int, _ yo: Int, _ sy: Int) {
                        switch op {
                        case .add: row(n, o + oo, xp + xo, sx, yp + yo, sy, +)
                        case .sub: row(n, o + oo, xp + xo, sx, yp + yo, sy, -)
                        case .mul: row(n, o + oo, xp + xo, sx, yp + yo, sy, *)
                        default: row(n, o + oo, xp + xo, sx, yp + yo, sy, /)
                        }
                    }
                    if x.shape == y.shape {
                        apply(count, 0, 0, 1, 0, 1)
                    } else if y.count == 1 {
                        apply(count, 0, 0, 1, 0, 0)
                    } else if x.count == 1 {
                        apply(count, 0, 0, 0, 0, 1)
                    } else {
                        forEachBroadcastRow(outShape: outShape, xStrides: xStrides, yStrides: yStrides, apply)
                    }
                }
            }
        }
    }

    @inline(__always)
    static func compare(_ op: BinaryOp, _ a: Float, _ b: Float) -> Bool {
        switch op {
        case .equal: a == b
        case .notEqual: a != b
        case .greater: a > b
        case .greaterEqual: a >= b
        case .less: a < b
        case .lessEqual: a <= b
        default: false
        }
    }

    static func select(_ args: MILArguments) throws -> MILTensor {
        let cond = try args.tensor("cond")
        let a = try args.tensor("a")
        let b = try args.tensor("b")
        let outShape = try broadcastShape(try broadcastShape(cond.shape, a.shape, args), b.shape, args)
        let co = broadcastOffsets(cond.shape, to: outShape)
        let ao = broadcastOffsets(a.shape, to: outShape)
        let bo = broadcastOffsets(b.shape, to: outShape)
        let condValues = cond.floats
        if a.hasFloatStorage || b.hasFloatStorage {
            let av = a.floats
            let bv = b.floats
            return makeFloat(outShape) { out in
                for i in 0..<out.count {
                    out[i] = condValues[co[i]] != 0 ? av[ao[i]] : bv[bo[i]]
                }
            }
        }
        let av = a.int32s
        let bv = b.int32s
        let out = (0..<co.count).map { condValues[co[$0]] != 0 ? av[ao[$0]] : bv[bo[$0]] }
        return MILTensor(dataType: .int32, shape: outShape, storage: .int(out))
    }

    static func cast(_ args: MILArguments) throws -> MILTensor {
        let x = try args.tensor("x")
        let name = try args.string("dtype")
        guard let target = MILDataType(rawValue: name), target != .string else {
            throw args.failure("unsupported cast target \(name)")
        }
        if target.isFloatingPoint {
            return MILTensor(dataType: target, shape: x.shape, storage: .float(floatStorage(x)))
        }
        let integers: [Int32] = switch x.storage {
        case .int(let values): values
        case .float(let storage): storage.withUnsafeBufferPointer { $0.map(truncatingToInt32) }
        }
        let wrapped: [Int32] = switch target {
        case .bool: integers.map { $0 != 0 ? 1 : 0 }
        case .int8: integers.map { Int32(Int8(truncatingIfNeeded: $0)) }
        case .uint8: integers.map { Int32(UInt8(truncatingIfNeeded: $0)) }
        case .int16: integers.map { Int32(Int16(truncatingIfNeeded: $0)) }
        case .uint16: integers.map { Int32(UInt16(truncatingIfNeeded: $0)) }
        default: integers
        }
        if target.usesFloatStorage {
            return MILTensor(dataType: target, shape: x.shape, storage: .float(MILFloatStorage(wrapped.map { Float($0) })))
        }
        return MILTensor(dataType: target, shape: x.shape, storage: .int(wrapped))
    }

    static func clip(_ args: MILArguments) throws -> MILTensor {
        let x = try args.tensor("x")
        let alpha = try args.float("alpha")
        let beta = try args.float("beta")
        return floatStorage(x).withUnsafeBufferPointer { input in
            makeFloat(x.shape) { out in
                for i in 0..<out.count { out[i] = min(max(input[i], alpha), beta) }
            }
        }
    }

    static func gelu(_ args: MILArguments, threads: Int) throws -> MILTensor {
        let x = try args.tensor("x")
        let mode: Int32 = switch try args.string("mode", default: "EXACT") {
        case "EXACT": 0
        case "TANH_APPROXIMATION": 1
        case "SIGMOID_APPROXIMATION": 2
        case let other: throw args.failure("unsupported gelu mode \(other)")
        }
        return floatStorage(x).withUnsafeBufferPointer { input in
            makeFloat(x.shape) { out in
                guard let o = out.baseAddress, let i = input.baseAddress else { return }
                let (source, destination) = (MILUnsafeSendable(i), MILUnsafeSendable(o))
                let workers = MILParallel.threads(forElements: out.count, maximum: threads)
                MILParallel.forEachChunk(of: out.count, threads: workers) { range in
                    wax_mil_gelu(source.value + range.lowerBound, destination.value + range.lowerBound, range.count, mode)
                }
            }
        }
    }

    static func tanh(_ args: MILArguments) throws -> MILTensor {
        let x = try args.tensor("x")
        return floatStorage(x).withUnsafeBufferPointer { input in
            makeFloat(x.shape) { out in wax_mil_tanh(input.baseAddress, out.baseAddress, out.count) }
        }
    }

    // MARK: - Normalisation

    static func layerNorm(_ args: MILArguments, threads: Int) throws -> MILTensor {
        let x = try args.tensor("x")
        let axes = try args.ints("axes").map { try args.axis($0, rank: x.rank) }.sorted()
        let trailing = Array((x.rank - axes.count)..<x.rank)
        guard !axes.isEmpty, axes == trailing else {
            throw args.failure("layer_norm over axes \(axes) is supported only for trailing axes")
        }
        let cols = axes.reduce(1) { $0 * x.shape[$1] }
        let rows = cols == 0 ? 0 : x.count / cols
        let gamma = try args.optionalTensor("gamma").map(floatStorage)
        let beta = try args.optionalTensor("beta").map(floatStorage)
        if let gamma, gamma.count != cols { throw args.failure("gamma has \(gamma.count) values for \(cols) features") }
        if let beta, beta.count != cols { throw args.failure("beta has \(beta.count) values for \(cols) features") }
        let epsilon = try args.float("epsilon", default: 1e-5)
        let workers = MILParallel.threads(forElements: x.count, maximum: threads)
        return floatStorage(x).withUnsafeBufferPointer { input in
            makeFloat(x.shape) { out in
                guard let o = out.baseAddress, let i = input.baseAddress else { return }
                let (source, destination) = (MILUnsafeSendable(i), MILUnsafeSendable(o))
                func run(_ g: UnsafePointer<Float>?, _ b: UnsafePointer<Float>?) {
                    let affine = MILUnsafeSendable((g, b))
                    MILParallel.forEachChunk(of: rows, threads: workers) { range in
                        let offset = range.lowerBound * cols
                        wax_mil_layer_norm(source.value + offset, destination.value + offset, range.count, cols,
                                           affine.value.0, affine.value.1, epsilon)
                    }
                }
                switch (gamma, beta) {
                case let (g?, b?): g.withUnsafeBufferPointer { gp in b.withUnsafeBufferPointer { bp in run(gp.baseAddress, bp.baseAddress) } }
                case let (g?, nil): g.withUnsafeBufferPointer { run($0.baseAddress, nil) }
                case let (nil, b?): b.withUnsafeBufferPointer { run(nil, $0.baseAddress) }
                case (nil, nil): run(nil, nil)
                }
            }
        }
    }

    static func softmax(_ args: MILArguments, threads: Int) throws -> MILTensor {
        let x = try args.tensor("x")
        let axis = try args.axis(try args.int("axis", default: -1), rank: x.rank)
        let length = x.rank == 0 ? 1 : x.shape[axis]
        let outer = x.rank == 0 ? 1 : x.shape[..<axis].reduce(1, *)
        let inner = x.rank == 0 ? 1 : x.shape[(axis + 1)...].reduce(1, *)
        let workers = MILParallel.threads(forElements: x.count, maximum: threads)
        return floatStorage(x).withUnsafeBufferPointer { input in
            makeFloat(x.shape) { out in
                guard let o = out.baseAddress, let i = input.baseAddress else { return }
                let (source, destination) = (MILUnsafeSendable(i), MILUnsafeSendable(o))
                MILParallel.forEachChunk(of: outer, threads: workers) { range in
                    let offset = range.lowerBound * length * inner
                    wax_mil_softmax(source.value + offset, destination.value + offset, range.count, length, inner)
                }
            }
        }
    }

    static func reduce(_ args: MILArguments, squared: Bool) throws -> MILTensor {
        let x = try args.tensor("x")
        let keepDims = try args.bool("keep_dims", default: false)
        let axes = Set(try (args.optionalInts("axes") ?? Array(0..<x.rank)).map { try args.axis($0, rank: x.rank) })
        var outShape: [Int] = []
        for d in 0..<x.rank {
            if axes.contains(d) {
                if keepDims { outShape.append(1) }
            } else {
                outShape.append(x.shape[d])
            }
        }
        let keptShape = (0..<x.rank).map { axes.contains($0) ? 1 : x.shape[$0] }
        let offsets = broadcastOffsets(keptShape, to: x.shape)
        let input = x.floats
        var sums = [Double](repeating: 0, count: keptShape.reduce(1, *))
        for i in 0..<input.count {
            let v = Double(input[i])
            sums[offsets[i]] += squared ? v * v : v
        }
        return makeFloat(outShape) { out in
            for i in 0..<out.count { out[i] = Float(squared ? sums[i].squareRoot() : sums[i]) }
        }
    }

    // MARK: - Linear algebra

    /// `x [..., K] · weightᵀ + bias` with `weight [N, K]`. Constant weights arrive pre-packed
    /// (`packed`); a weight computed at run time is packed here. Column panels are split across
    /// threads when the product is large enough.
    static func linear(_ args: MILArguments, packed: MILPackedMatrix?, threads: Int) throws -> MILTensor {
        let x = try args.tensor("x")
        let weights: MILPackedMatrix
        if let packed {
            weights = packed
        } else {
            let weight = try args.tensor("weight")
            guard weight.rank == 2 else { throw args.failure("linear weight must be [N, K]; got \(weight.shape)") }
            weights = MILPackedMatrix(weight: weight)
        }
        let (n, k) = (weights.n, weights.k)
        guard x.rank >= 1, x.shape[x.rank - 1] == k else {
            throw args.failure("linear needs x [..., \(k)] for weight [\(n), \(k)]; got \(x.shape)")
        }
        let m = k == 0 ? 0 : x.count / k
        let bias = try args.optionalTensor("bias").map(floatStorage)
        if let bias, bias.count != n { throw args.failure("bias has \(bias.count) values for \(n) outputs") }
        let outShape = Array(x.shape.dropLast()) + [n]
        let workers = MILParallel.threads(forWork: m * n * k, maximum: threads)
        let panels = (n + Int(WAX_MIL_SGEMM_NR) - 1) / Int(WAX_MIL_SGEMM_NR)
        return floatStorage(x).withUnsafeBufferPointer { xb in
            weights.withPanels { panelBase in
                makeFloat(outShape) { out in
                    guard let o = out.baseAddress, let xBase = xb.baseAddress else { return }
                    if let bias {
                        bias.withUnsafeBufferPointer { bb in
                            guard let b = bb.baseAddress else { return }
                            for r in 0..<m { (o + r * n).update(from: b, count: n) }
                        }
                    }
                    let beta: Float = bias == nil ? 0 : 1
                    let output = MILUnsafeSendable(o)
                    let input = MILUnsafeSendable(xBase)
                    let panelsPointer = MILUnsafeSendable(panelBase)
                    MILParallel.forEachChunk(of: panels, threads: workers) { range in
                        let nr = Int(WAX_MIL_SGEMM_NR)
                        wax_mil_sgemm_packed(0, m, n, k, input.value, k, panelsPointer.value,
                                             range.lowerBound * nr, min(range.upperBound * nr, n),
                                             beta, output.value, n)
                    }
                }
            }
        }
    }

    /// Batched matrix product with broadcast batch axes; batches are split across threads.
    static func matmul(_ args: MILArguments, threads: Int) throws -> MILTensor {
        var x = try args.tensor("x")
        var y = try args.tensor("y")
        let transposeX = try args.bool("transpose_x", default: false)
        let transposeY = try args.bool("transpose_y", default: false)
        guard x.rank >= 1, y.rank >= 1 else { throw args.failure("matmul needs tensors of rank 1 or more") }
        let vectorX = x.rank == 1
        let vectorY = y.rank == 1
        if vectorX { x = x.retyped(x.dataType, shape: [1, x.shape[0]]) }
        if vectorY { y = y.retyped(y.dataType, shape: [y.shape[0], 1]) }
        let xRows = x.shape[x.rank - 2], xCols = x.shape[x.rank - 1]
        let yRows = y.shape[y.rank - 2], yCols = y.shape[y.rank - 1]
        let tx: Int32 = transposeX && !vectorX ? 1 : 0
        let ty: Int32 = transposeY && !vectorY ? 1 : 0
        let m = tx == 1 ? xCols : xRows
        let k = tx == 1 ? xRows : xCols
        let ky = ty == 1 ? yCols : yRows
        let n = ty == 1 ? yRows : yCols
        guard k == ky else { throw args.failure("matmul inner dimensions differ: \(x.shape) x \(y.shape)") }
        let xBatch = Array(x.shape.dropLast(2))
        let yBatch = Array(y.shape.dropLast(2))
        let batch = try broadcastShape(xBatch, yBatch, args)
        let batches = batch.reduce(1, *)
        let xOffsets = broadcastOffsets(xBatch, to: batch)
        let yOffsets = broadcastOffsets(yBatch, to: batch)
        var outShape = batch + [m, n]
        if vectorX { outShape.remove(at: outShape.count - 2) }
        if vectorY { outShape.removeLast() }
        let workers = MILParallel.threads(forWork: batches * m * n * k, maximum: threads)
        return floatStorage(x).withUnsafeBufferPointer { xb in
            floatStorage(y).withUnsafeBufferPointer { yb in
                makeFloat(outShape) { out in
                    guard let o = out.baseAddress, let xBase = xb.baseAddress, let yBase = yb.baseAddress else { return }
                    let output = MILUnsafeSendable(o)
                    let left = MILUnsafeSendable(xBase)
                    let right = MILUnsafeSendable(yBase)
                    MILParallel.forEachChunk(of: batches, threads: workers) { range in
                        for b in range {
                            wax_mil_sgemm(tx, ty, m, n, k,
                                          left.value + xOffsets[b] * xRows * xCols, xCols,
                                          right.value + yOffsets[b] * yRows * yCols, yCols,
                                          0, output.value + b * m * n, n)
                        }
                    }
                }
            }
        }
    }

    // MARK: - Shape and data movement

    static func shape(_ args: MILArguments) throws -> MILTensor {
        let x = try args.tensor("x")
        return MILTensor(dataType: .int32, shape: [x.rank], storage: .int(x.shape.map { Int32($0) }))
    }

    static func reshape(_ args: MILArguments) throws -> MILTensor {
        let x = try args.tensor("x")
        var shape = try args.ints("shape")
        var inferred: Int?
        for (d, size) in shape.enumerated() {
            if size == -1 {
                guard inferred == nil else { throw args.failure("reshape has more than one -1 in \(shape)") }
                inferred = d
            } else if size == 0 {
                // iOS 17+: 0 copies the input dimension.
                guard d < x.rank else { throw args.failure("reshape 0 at axis \(d) has no input dimension") }
                shape[d] = x.shape[d]
            } else if size < 0 {
                throw args.failure("invalid reshape dimension \(size)")
            }
        }
        if let inferred {
            let known = shape.enumerated().reduce(1) { $1.offset == inferred ? $0 : $0 * $1.element }
            guard known > 0, x.count % known == 0 else { throw args.failure("cannot reshape \(x.shape) to \(shape)") }
            shape[inferred] = x.count / known
        }
        guard shape.reduce(1, *) == x.count else { throw args.failure("cannot reshape \(x.shape) to \(shape)") }
        return x.retyped(x.dataType, shape: shape)
    }

    static func expandDims(_ args: MILArguments) throws -> MILTensor {
        let x = try args.tensor("x")
        let raw = try args.ints("axes")
        let outRank = x.rank + raw.count
        let axes = try raw.map { try args.axis($0, rank: outRank) }.sorted()
        guard Set(axes).count == axes.count else { throw args.failure("duplicate expand_dims axes \(raw)") }
        var shape = x.shape
        for axis in axes { shape.insert(1, at: axis) }
        return x.retyped(x.dataType, shape: shape)
    }

    /// Copies `count` elements: out[i] = in[offsets[i]], for either storage.
    static func gatherElements(_ x: MILTensor, shape: [Int], offsets: [Int]) -> MILTensor {
        switch x.storage {
        case .int(let values):
            return MILTensor(dataType: x.dataType, shape: shape, storage: .int(offsets.map { values[$0] }))
        case .float(let storage):
            let result = storage.withUnsafeBufferPointer { input in
                makeFloat(shape) { out in
                    for i in 0..<out.count { out[i] = input[offsets[i]] }
                }
            }
            return result.retyped(x.dataType)
        }
    }

    static func gather(_ args: MILArguments) throws -> MILTensor {
        let x = try args.tensor("x")
        let indices = try args.tensor("indices")
        guard try args.int("batch_dims", default: 0) == 0 else { throw args.failure("gather with batch_dims != 0 is not supported") }
        guard x.rank >= 1 else { throw args.failure("gather needs x of rank 1 or more") }
        let axis = try args.axis(try args.int("axis", default: 0), rank: x.rank)
        let dim = x.shape[axis]
        let outer = x.shape[..<axis].reduce(1, *)
        let inner = x.shape[(axis + 1)...].reduce(1, *)
        let picks = try indices.int32s.map { raw -> Int in
            let index = Int(raw) < 0 ? Int(raw) + dim : Int(raw)
            guard index >= 0, index < dim else { throw args.failure("gather index \(raw) is out of range for axis size \(dim)") }
            return index
        }
        let outShape = Array(x.shape[..<axis]) + indices.shape + Array(x.shape[(axis + 1)...])
        switch x.storage {
        case .float(let storage):
            let result = storage.withUnsafeBufferPointer { input in
                makeFloat(outShape) { out in
                    guard let o = out.baseAddress, let base = input.baseAddress else { return }
                    var position = 0
                    for block in 0..<outer {
                        for index in picks {
                            (o + position).update(from: base + (block * dim + index) * inner, count: inner)
                            position += inner
                        }
                    }
                }
            }
            return result.retyped(x.dataType)
        case .int(let values):
            var out: [Int32] = []
            out.reserveCapacity(outer * picks.count * inner)
            for block in 0..<outer {
                for index in picks {
                    let start = (block * dim + index) * inner
                    out.append(contentsOf: values[start..<(start + inner)])
                }
            }
            return MILTensor(dataType: x.dataType, shape: outShape, storage: .int(out))
        }
    }

    static func sliceByIndex(_ args: MILArguments) throws -> MILTensor {
        let x = try args.tensor("x")
        let rank = x.rank
        let begin = try args.ints("begin")
        let end = try args.ints("end")
        let strides = try args.optionalInts("stride") ?? [Int](repeating: 1, count: rank)
        let beginMask = try args.bools("begin_mask") ?? [Bool](repeating: false, count: rank)
        let endMask = try args.bools("end_mask") ?? [Bool](repeating: false, count: rank)
        let squeezeMask = try args.bools("squeeze_mask") ?? [Bool](repeating: false, count: rank)
        guard [begin.count, end.count, strides.count, beginMask.count, endMask.count, squeezeMask.count].allSatisfy({ $0 == rank }) else {
            throw args.failure("slice_by_index arguments must each have \(rank) entries")
        }
        var starts: [Int] = []
        var steps: [Int] = []
        var sizes: [Int] = []
        var outShape: [Int] = []
        for d in 0..<rank {
            let dim = x.shape[d]
            let step = strides[d]
            guard step != 0 else { throw args.failure("slice stride cannot be 0") }
            var start: Int
            var size: Int
            if squeezeMask[d] {
                start = begin[d] < 0 ? begin[d] + dim : begin[d]
                guard start >= 0, start < dim else { throw args.failure("squeezed index \(begin[d]) is out of range for size \(dim)") }
                size = 1
            } else if step > 0 {
                start = beginMask[d] ? 0 : (begin[d] < 0 ? begin[d] + dim : begin[d])
                var stop = endMask[d] ? dim : (end[d] < 0 ? end[d] + dim : end[d])
                start = min(max(start, 0), dim)
                stop = min(max(stop, 0), dim)
                size = stop > start ? (stop - start + step - 1) / step : 0
            } else {
                start = beginMask[d] ? dim - 1 : (begin[d] < 0 ? begin[d] + dim : begin[d])
                var stop = endMask[d] ? -1 : (end[d] < 0 ? end[d] + dim : end[d])
                start = min(max(start, -1), dim - 1)
                stop = min(max(stop, -1), dim - 1)
                size = start > stop ? (start - stop - step - 1) / -step : 0
            }
            starts.append(start)
            steps.append(step)
            sizes.append(size)
            if !squeezeMask[d] { outShape.append(size) }
        }
        let inStrides = contiguousStrides(x.shape)
        let count = sizes.reduce(1, *)
        var offsets = [Int](repeating: 0, count: count)
        if count > 0 {
            var index = [Int](repeating: 0, count: rank)
            for linear in 0..<count {
                var offset = 0
                for d in 0..<rank { offset += (starts[d] + index[d] * steps[d]) * inStrides[d] }
                offsets[linear] = offset
                var d = rank - 1
                while d >= 0 {
                    index[d] += 1
                    if index[d] < sizes[d] { break }
                    index[d] = 0
                    d -= 1
                }
            }
        }
        return gatherElements(x, shape: outShape, offsets: offsets)
    }

    static func transpose(_ args: MILArguments) throws -> MILTensor {
        let x = try args.tensor("x")
        let perm = try args.ints("perm").map { try args.axis($0, rank: x.rank) }
        guard perm.count == x.rank, Set(perm).count == perm.count else {
            throw args.failure("perm \(perm) is not a permutation of rank \(x.rank)")
        }
        let outShape = perm.map { x.shape[$0] }
        let inStrides = contiguousStrides(x.shape)
        let permutedStrides = perm.map { inStrides[$0] }
        guard case .float(let storage) = x.storage else {
            let offsets = permutedOffsets(outShape: outShape, strides: permutedStrides)
            return gatherElements(x, shape: outShape, offsets: offsets)
        }
        let rank = outShape.count
        let result = storage.withUnsafeBufferPointer { input in
            makeFloat(outShape) { out in
                guard rank > 0, let o = out.baseAddress, let base = input.baseAddress, out.count > 0 else {
                    if out.count == 1 { out[0] = input[0] }
                    return
                }
                let length = outShape[rank - 1]
                let innerStride = permutedStrides[rank - 1]
                let rows = out.count / length
                var index = [Int](repeating: 0, count: rank - 1)
                for row in 0..<rows {
                    var offset = 0
                    for d in 0..<(rank - 1) { offset += index[d] * permutedStrides[d] }
                    let destination = o + row * length
                    let source = base + offset
                    if innerStride == 1 {
                        destination.update(from: source, count: length)
                    } else {
                        for j in 0..<length { destination[j] = source[j * innerStride] }
                    }
                    var d = rank - 2
                    while d >= 0 {
                        index[d] += 1
                        if index[d] < outShape[d] { break }
                        index[d] = 0
                        d -= 1
                    }
                }
            }
        }
        return result.retyped(x.dataType)
    }

    static func permutedOffsets(outShape: [Int], strides: [Int]) -> [Int] {
        let count = outShape.reduce(1, *)
        var offsets = [Int](repeating: 0, count: count)
        guard count > 0 else { return offsets }
        var index = [Int](repeating: 0, count: outShape.count)
        for linear in 0..<count {
            var offset = 0
            for d in 0..<outShape.count { offset += index[d] * strides[d] }
            offsets[linear] = offset
            var d = outShape.count - 1
            while d >= 0 {
                index[d] += 1
                if index[d] < outShape[d] { break }
                index[d] = 0
                d -= 1
            }
        }
        return offsets
    }

    static func tile(_ args: MILArguments) throws -> MILTensor {
        let x = try args.tensor("x")
        let reps = try args.ints("reps")
        guard reps.count == x.rank, reps.allSatisfy({ $0 >= 0 }) else {
            throw args.failure("tile reps \(reps) must have \(x.rank) non-negative entries")
        }
        let outShape = zip(x.shape, reps).map { $0 * $1 }
        let inStrides = contiguousStrides(x.shape)
        let count = outShape.reduce(1, *)
        var offsets = [Int](repeating: 0, count: count)
        if count > 0 {
            var index = [Int](repeating: 0, count: x.rank)
            for linear in 0..<count {
                var offset = 0
                for d in 0..<x.rank { offset += (index[d] % x.shape[d]) * inStrides[d] }
                offsets[linear] = offset
                var d = x.rank - 1
                while d >= 0 {
                    index[d] += 1
                    if index[d] < outShape[d] { break }
                    index[d] = 0
                    d -= 1
                }
            }
        }
        return gatherElements(x, shape: outShape, offsets: offsets)
    }

    static func concat(_ args: MILArguments) throws -> MILTensor {
        let values = try args.tensors("values").map { $0.rank == 0 ? $0.retyped($0.dataType, shape: [1]) : $0 }
        guard !values.isEmpty else { throw args.failure("concat needs at least one value") }
        guard try !args.bool("interleave", default: false) else { throw args.failure("concat with interleave is not supported") }
        let rank = values[0].rank
        let axis = try args.axis(try args.int("axis"), rank: rank)
        for value in values {
            guard value.rank == rank,
                  (0..<rank).allSatisfy({ $0 == axis || value.shape[$0] == values[0].shape[$0] })
            else { throw args.failure("concat shapes \(values.map(\.shape)) disagree off axis \(axis)") }
        }
        var outShape = values[0].shape
        outShape[axis] = values.reduce(0) { $0 + $1.shape[axis] }
        let outer = outShape[..<axis].reduce(1, *)
        let inner = outShape[(axis + 1)...].reduce(1, *)
        if values.allSatisfy({ !$0.hasFloatStorage }) {
            var out: [Int32] = []
            out.reserveCapacity(outShape.reduce(1, *))
            let arrays = values.map(\.int32s)
            for block in 0..<outer {
                for (value, array) in zip(values, arrays) {
                    let chunk = value.shape[axis] * inner
                    out.append(contentsOf: array[(block * chunk)..<((block + 1) * chunk)])
                }
            }
            return MILTensor(dataType: values[0].dataType, shape: outShape, storage: .int(out))
        }
        let arrays = values.map(\.floats)
        return makeFloat(outShape) { out in
            var position = 0
            for block in 0..<outer {
                for (value, array) in zip(values, arrays) {
                    let chunk = value.shape[axis] * inner
                    for j in 0..<chunk { out[position + j] = array[block * chunk + j] }
                    position += chunk
                }
            }
        }
    }

    // MARK: - Weight decompression

    static func blockwiseShiftScale(_ args: MILArguments) throws -> MILTensor {
        let data = try args.tensor("data")
        let scale = try args.tensor("scale")
        let offset = try args.optionalTensor("offset")
        guard data.rank >= 1, data.rank <= 8, scale.rank == data.rank else {
            throw args.failure("scale rank \(scale.rank) must equal data rank \(data.rank) (1...8)")
        }
        for d in 0..<data.rank where scale.shape[d] == 0 || data.shape[d] % scale.shape[d] != 0 {
            throw args.failure("data shape \(data.shape) is not a multiple of scale shape \(scale.shape)")
        }
        if let offset, offset.shape != scale.shape {
            throw args.failure("offset shape \(offset.shape) must equal scale shape \(scale.shape)")
        }
        let shape = data.shape.map { $0 }
        let scaleShape = scale.shape.map { $0 }
        let offsetStorage = offset.map(floatStorage)
        return floatStorage(data).withUnsafeBufferPointer { input in
            floatStorage(scale).withUnsafeBufferPointer { scales in
                makeFloat(shape) { out in
                    guard let o = out.baseAddress, let i = input.baseAddress else { return }
                    o.update(from: i, count: out.count)
                    func run(_ offsets: UnsafePointer<Float>?) {
                        wax_mil_blockwise_dequantize(o, shape.count, shape, scales.baseAddress, offsets, scaleShape)
                    }
                    if let offsetStorage {
                        offsetStorage.withUnsafeBufferPointer { run($0.baseAddress) }
                    } else {
                        run(nil)
                    }
                }
            }
        }
    }
}
