import Testing
@testable import WaxCore

private actor CriticalSectionProbe {
    private var active = 0
    private var maxActive = 0

    func enter() {
        active += 1
        if active > maxActive {
            maxActive = active
        }
    }

    func leave() {
        active -= 1
    }

    func snapshot() -> (active: Int, maxActive: Int) {
        (active: active, maxActive: maxActive)
    }
}

private enum AsyncMutexTestError: Error {
    case expected
}

@Test
func asyncMutexSerializesContendedCriticalSections() async {
    let mutex = AsyncMutex()
    let probe = CriticalSectionProbe()

    await withTaskGroup(of: Void.self) { group in
        for _ in 0..<16 {
            group.addTask {
                await mutex.withLock {
                    await probe.enter()
                    await Task.yield()
                    await Task.yield()
                    await probe.leave()
                }
            }
        }
        await group.waitForAll()
    }

    let snapshot = await probe.snapshot()
    #expect(snapshot.active == 0)
    #expect(snapshot.maxActive == 1)
}

@Test
func asyncMutexWithLockReleasesAfterError() async {
    let mutex = AsyncMutex()

    do {
        _ = try await mutex.withLock {
            throw AsyncMutexTestError.expected
        }
        #expect(Bool(false))
    } catch AsyncMutexTestError.expected {
        // Expected path.
    } catch {
        #expect(Bool(false))
    }

    await mutex.lock()
    await mutex.unlock()
}
