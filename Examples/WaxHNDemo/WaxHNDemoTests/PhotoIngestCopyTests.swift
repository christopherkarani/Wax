import Testing
@testable import WaxHNDemo

@Suite("Photo ingest copy")
struct PhotoIngestCopyTests {
    @Test("All-stub report is obvious and tells Mac users to drop files")
    func allStubsOnMac() {
        let report = PhotoIngestReport(requested: 8, searchable: 0, iCloudOnly: 8)
        #expect(report.allStubs)
        #expect(PhotoIngestCopy.bannerTitle(for: report) == "These photos are not on this device")
        #expect(
            PhotoIngestCopy.bannerBody(for: report, surface: .mac)
                == "0 of 8 have pixels on this device. 8 are iCloud-only, so Wax stored empty stubs with no OCR and search will miss them. Drop the original image files onto this window."
        )
        #expect(
            PhotoIngestCopy.emptySearchNotice(report: report)
                == "No matching photos. 8 of 8 picked items were iCloud-only stubs with no text to search."
        )
        #expect(PhotoIngestCopy.photosSuccess(report: report) == nil)
    }

    @Test("All-stub report tells iPad users to download in Photos")
    func allStubsOnIPad() {
        let report = PhotoIngestReport(requested: 8, searchable: 0, iCloudOnly: 8)
        #expect(
            PhotoIngestCopy.bannerBody(for: report, surface: .iPadOrIPhone)
                == "0 of 8 have pixels on this device. 8 are iCloud-only, so Wax stored empty stubs with no OCR and search will miss them. Open those photos in Photos so they download, then pick them again. Wax does not fetch iCloud originals."
        )
    }

    @Test("Partial iCloud mix keeps a warning")
    func partialStubs() {
        let report = PhotoIngestReport(requested: 8, searchable: 2, iCloudOnly: 6)
        #expect(!report.allStubs)
        #expect(report.hasICloudStubs)
        #expect(PhotoIngestCopy.bannerTitle(for: report) == "Some photos are still in iCloud")
        #expect(
            PhotoIngestCopy.bannerBody(for: report, surface: .mac)
                .contains("2 of 8 have pixels on this device. 6 are iCloud-only")
        )
    }

    @Test("On-device Photos ingest has no warning")
    func allLocal() {
        let report = PhotoIngestReport(requested: 3, searchable: 3, iCloudOnly: 0)
        #expect(!report.hasICloudStubs)
        #expect(PhotoIngestCopy.photosSuccess(report: report) == "Indexed 3 photos.")
        #expect(PhotoIngestCopy.emptySearchNotice(report: report) == "No matching photos.")
    }

    @Test("Empty-state copy warns both surfaces about iCloud stubs")
    func emptyState() {
        #expect(PhotoIngestCopy.emptyStateTitle(surface: .mac) == "Drop on-device photos, then ask")
        #expect(PhotoIngestCopy.emptyStateTitle(surface: .iPadOrIPhone) == "Pick on-device photos, then ask")
        #expect(PhotoIngestCopy.emptyStateBody(surface: .mac).contains("iCloud"))
        #expect(PhotoIngestCopy.emptyStateBody(surface: .iPadOrIPhone).contains("iCloud"))
        #expect(PhotoIngestCopy.emptyStateBody(surface: .mac).contains("Drop"))
        #expect(PhotoIngestCopy.emptyStateBody(surface: .iPadOrIPhone).contains("download"))
    }

    @Test("Builds a report from a store probe")
    func reportFromProbe() {
        let allStubs = PhotoIngestReport.fromProbe(requested: 8, returned: 8, degraded: 8)
        #expect(allStubs == PhotoIngestReport(requested: 8, searchable: 0, iCloudOnly: 8))
        let mixed = PhotoIngestReport.fromProbe(requested: 8, returned: 8, degraded: 6)
        #expect(mixed == PhotoIngestReport(requested: 8, searchable: 2, iCloudOnly: 6))
        let emptyProbe = PhotoIngestReport.fromProbe(requested: 8, returned: 0, degraded: 0)
        #expect(emptyProbe == PhotoIngestReport(requested: 8, searchable: 0, iCloudOnly: 8))
    }
}
