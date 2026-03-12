@preconcurrency import Dispatch

package struct WaxOptions: Sendable {
    package var walFsyncPolicy: WALFsyncPolicy
    package var walProactiveCommitThresholdPercent: UInt8?
    package var walProactiveCommitMaxWalSizeBytes: UInt64?
    package var walProactiveCommitMinPendingBytes: UInt64
    package var walReplayStateSnapshotEnabled: Bool
    package var ioQueueLabel: String
    package var ioQueueQosClass: DispatchQoS.QoSClass
    package var ioQueueRelativePriority: Int

    package var ioQueueQos: DispatchQoS {
        get {
            DispatchQoS(
                qosClass: ioQueueQosClass,
                relativePriority: ioQueueRelativePriority
            )
        }
        set {
            ioQueueQosClass = newValue.qosClass
            ioQueueRelativePriority = newValue.relativePriority
        }
    }

    package init(
        walFsyncPolicy: WALFsyncPolicy = .onCommit,
        walProactiveCommitThresholdPercent: UInt8? = 80,
        walProactiveCommitMaxWalSizeBytes: UInt64? = 4 * 1024 * 1024,
        walProactiveCommitMinPendingBytes: UInt64 = 128 * 1024,
        walReplayStateSnapshotEnabled: Bool = false,
        ioQueueLabel: String = "com.wax.io",
        ioQueueQos: DispatchQoS = .userInitiated
    ) {
        self.walFsyncPolicy = walFsyncPolicy
        self.walProactiveCommitThresholdPercent = walProactiveCommitThresholdPercent
        self.walProactiveCommitMaxWalSizeBytes = walProactiveCommitMaxWalSizeBytes
        self.walProactiveCommitMinPendingBytes = walProactiveCommitMinPendingBytes
        self.walReplayStateSnapshotEnabled = walReplayStateSnapshotEnabled
        self.ioQueueLabel = ioQueueLabel
        self.ioQueueQosClass = ioQueueQos.qosClass
        self.ioQueueRelativePriority = ioQueueQos.relativePriority
    }
}
