#if canImport(Darwin)
import Darwin
import Dispatch
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

/// Async work that runs long synchronous stretches (tokenizing, for one) must run them,
/// and the default actors it calls, off the cooperative pool.
@available(macOS 15.0, iOS 18.0, *)
@Test
func blockingWorkRunAsyncRunsOffTheCooperativePool() async {
    let labels = await BlockingWork.runAsync {
        let own = currentQueueLabel()
        let actorLabel = await QueueLabelProbe().label()
        return [own, actorLabel]
    }
    for label in labels {
        #expect(!label.contains("cooperative"), "\(label)")
    }
}

private func currentQueueLabel() -> String {
    String(cString: __dispatch_queue_get_label(nil))
}

private actor QueueLabelProbe {
    func label() -> String { currentQueueLabel() }
}
#endif
