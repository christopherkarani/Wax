#if canImport(Darwin)
import Darwin
import Testing
@testable import WaxCore

/// Blocking work stands in for an inline call the caller is waiting on, so it
/// must not run at a lower QoS than the caller. On a loaded host, work demoted
/// below the test and request threads waits seconds for a core.
@Test(arguments: [TaskPriority.userInitiated, .medium])
func blockingWorkKeepsTheCallersQoS(priority: TaskPriority) async {
    let (callerQoS, workQoS) = await Task(priority: priority) {
        let caller = qos_class_self()
        let work = await BlockingWork.run { qos_class_self() }
        return (caller, work)
    }.value

    #expect(workQoS.rawValue >= callerQoS.rawValue)
}
#endif
