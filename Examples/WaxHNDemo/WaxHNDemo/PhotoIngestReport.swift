struct PhotoIngestReport: Equatable, Sendable {
    var requested: Int
    var searchable: Int
    var iCloudOnly: Int

    var hasICloudStubs: Bool { iCloudOnly > 0 }
    var allStubs: Bool { requested > 0 && searchable == 0 }

    static func fromProbe(requested: Int, returned: Int, degraded: Int) -> PhotoIngestReport {
        guard returned > 0 else {
            return PhotoIngestReport(requested: requested, searchable: 0, iCloudOnly: requested)
        }
        let searchable = max(0, returned - degraded)
        return PhotoIngestReport(
            requested: requested,
            searchable: searchable,
            iCloudOnly: max(0, requested - searchable)
        )
    }
}
