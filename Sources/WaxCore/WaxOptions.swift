import Dispatch

public struct WaxOptions: Sendable {
    public var walFsyncPolicy: WALFsyncPolicy
    public var walProactiveCommitThresholdPercent: UInt8?
    public var walProactiveCommitMaxWalSizeBytes: UInt64?
    public var walProactiveCommitMinPendingBytes: UInt64
    public var ioQueueLabel: String
    public var ioQueueQos: DispatchQoS

    public init(
        walFsyncPolicy: WALFsyncPolicy = .onCommit,
        walProactiveCommitThresholdPercent: UInt8? = 80,
        walProactiveCommitMaxWalSizeBytes: UInt64? = 4 * 1024 * 1024,
        walProactiveCommitMinPendingBytes: UInt64 = 128 * 1024,
        ioQueueLabel: String = "com.wax.io",
        ioQueueQos: DispatchQoS = .userInitiated
    ) {
        self.walFsyncPolicy = walFsyncPolicy
        self.walProactiveCommitThresholdPercent = walProactiveCommitThresholdPercent
        self.walProactiveCommitMaxWalSizeBytes = walProactiveCommitMaxWalSizeBytes
        self.walProactiveCommitMinPendingBytes = walProactiveCommitMinPendingBytes
        self.ioQueueLabel = ioQueueLabel
        self.ioQueueQos = ioQueueQos
    }
}
