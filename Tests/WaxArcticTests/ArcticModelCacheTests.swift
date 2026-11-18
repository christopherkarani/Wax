#if canImport(WaxVectorSearchArctic) && canImport(CoreML)
import CoreML
import Foundation
import Testing
@testable import WaxVectorSearchArctic

private struct LoaderReached: Error {
    let computeUnits: MLComputeUnits
}

/// A GPU load of this model can sit in MPSGraph shape solving for many minutes. While it does,
/// a CPU load of the same model must still run. The injected loader blocks on the GPU
/// configuration and throws a marker for every other one, so no real model is loaded.
@available(macOS 15.0, iOS 18.0, *)
@Test func arcticModelCacheDoesNotBlockACPULoadBehindAStalledGPULoad() throws {
    let gpuStarted = DispatchSemaphore(value: 0)
    let releaseGPU = DispatchSemaphore(value: 0)
    let gpuFinished = DispatchSemaphore(value: 0)
    let cpuFinished = DispatchSemaphore(value: 0)
    let cache = ArcticEmbeddings.ModelCache { configuration in
        if configuration.computeUnits == .cpuAndGPU {
            gpuStarted.signal()
            releaseGPU.wait()
        }
        throw LoaderReached(computeUnits: configuration.computeUnits)
    }

    Thread.detachNewThread {
        let configuration = MLModelConfiguration()
        configuration.computeUnits = .cpuAndGPU
        _ = try? cache.model(configuration: configuration)
        gpuFinished.signal()
    }
    // Deadlock guards only: a regression must fail, not hang the suite.
    #expect(gpuStarted.wait(timeout: .now() + .seconds(30)) == .success)

    let cpuOutcome = OutcomeBox()
    Thread.detachNewThread {
        let configuration = MLModelConfiguration()
        configuration.computeUnits = .cpuOnly
        do {
            _ = try cache.model(configuration: configuration)
        } catch let reached as LoaderReached {
            cpuOutcome.set(reached.computeUnits)
        } catch {}
        cpuFinished.signal()
    }

    let cpuCompleted = cpuFinished.wait(timeout: .now() + .seconds(30)) == .success
    releaseGPU.signal()
    #expect(gpuFinished.wait(timeout: .now() + .seconds(30)) == .success)
    if !cpuCompleted { _ = cpuFinished.wait(timeout: .now() + .seconds(30)) }

    #expect(cpuCompleted, "the CPU load waited behind the in-flight GPU load")
    #expect(cpuOutcome.get() == .cpuOnly)
}

private final class OutcomeBox: @unchecked Sendable {
    private let lock = NSLock()
    private var units: MLComputeUnits?
    func set(_ value: MLComputeUnits) { lock.withLock { units = value } }
    func get() -> MLComputeUnits? { lock.withLock { units } }
}
#endif
