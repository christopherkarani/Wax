enum PhotoIngestSurface: Sendable {
    case mac
    case iPadOrIPhone

    static var current: PhotoIngestSurface {
        #if os(macOS)
        .mac
        #else
        .iPadOrIPhone
        #endif
    }
}

enum PhotoIngestCopy {
    static func bannerTitle(for report: PhotoIngestReport) -> String {
        if report.allStubs {
            "These photos are not on this device"
        } else {
            "Some photos are still in iCloud"
        }
    }

    static func bannerBody(for report: PhotoIngestReport, surface: PhotoIngestSurface) -> String {
        let verb = report.iCloudOnly == 1 ? "is" : "are"
        let counts =
            "\(report.searchable) of \(report.requested) have pixels on this device. \(report.iCloudOnly) \(verb) iCloud-only, so Wax stored empty stubs with no OCR and search will miss them."
        switch surface {
        case .mac:
            return counts + " Drop the original image files onto this window."
        case .iPadOrIPhone:
            return counts
                + " Open those photos in Photos so they download, then pick them again. Wax does not fetch iCloud originals."
        }
    }

    static func emptyStateTitle(surface: PhotoIngestSurface) -> String {
        switch surface {
        case .mac:
            "Drop on-device photos, then ask"
        case .iPadOrIPhone:
            "Pick on-device photos, then ask"
        }
    }

    static func emptyStateBody(surface: PhotoIngestSurface) -> String {
        switch surface {
        case .mac:
            "Wax only indexes pixels stored on this Mac. iCloud Photos items that are not downloaded become empty stubs — search will return nothing. Drop PNG/JPEG files from Finder."
        case .iPadOrIPhone:
            "Wax only indexes pixels stored on this iPad or iPhone. iCloud Photos items that are not downloaded become empty stubs — search will return nothing. Open the photo in Photos until it finishes downloading, then pick it again."
        }
    }

    static func emptySearchNotice(report: PhotoIngestReport?) -> String {
        guard let report, report.hasICloudStubs else {
            return "No matching photos."
        }
        return "No matching photos. \(report.iCloudOnly) of \(report.requested) picked items were iCloud-only stubs with no text to search."
    }

    static func photosSuccess(report: PhotoIngestReport) -> String? {
        guard !report.hasICloudStubs else { return nil }
        return "Indexed \(report.searchable) photo\(report.searchable == 1 ? "" : "s")."
    }

    static func fileSuccess(count: Int) -> String {
        "Indexed \(count) file\(count == 1 ? "" : "s") from disk. Search for text in the frame."
    }
}
