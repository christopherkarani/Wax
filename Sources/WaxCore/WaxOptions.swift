import Dispatch

public struct WaxOptions: Sendable {
    public var walFsyncPolicy: WALFsyncPolicy
    public var walProactiveCommitThresholdPercent: UInt8?
    public var ioQueueLabel: String
    public var ioQueueQos: DispatchQoS

    public init(
        walFsyncPolicy: WALFsyncPolicy = .onCommit,
        walProactiveCommitThresholdPercent: UInt8? = nil,
        ioQueueLabel: String = "com.wax.io",
        ioQueueQos: DispatchQoS = .userInitiated
    ) {
        self.walFsyncPolicy = walFsyncPolicy
        self.walProactiveCommitThresholdPercent = walProactiveCommitThresholdPercent
        self.ioQueueLabel = ioQueueLabel
        self.ioQueueQos = ioQueueQos
    }
}
