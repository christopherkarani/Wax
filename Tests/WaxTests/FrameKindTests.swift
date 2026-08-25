import Foundation
import Testing
@testable import Wax

struct FrameKindTests {
    private static let literalWrittenKinds: [String?] = [
        nil,
        "surrogate",
        "handoff",
        "enrichment",
        "wax.internal.access_stats",
        "note",
    ]

    @Test
    func everyWrittenKindRoundTripsByteIdentically() {
        for raw in Self.literalWrittenKinds {
            #expect(FrameKind(rawKind: raw).storageValue == raw)
        }
        for raw in PhotoFrameKind.allCases.map(\.rawValue) {
            #expect(FrameKind(rawKind: raw).storageValue == raw)
        }
        for raw in VideoFrameKind.allCases.map(\.rawValue) {
            #expect(FrameKind(rawKind: raw).storageValue == raw)
        }
    }

    @Test
    func knownKindsParseToTypedCases() {
        #expect(FrameKind(rawKind: "surrogate") == .surrogate)
        #expect(FrameKind(rawKind: "handoff") == .handoff)
        #expect(FrameKind(rawKind: PhotoFrameKind.root.rawValue) == .photo(.root))
        #expect(FrameKind(rawKind: PhotoFrameKind.syncState.rawValue) == .photo(.syncState))
        #expect(FrameKind(rawKind: VideoFrameKind.segment.rawValue) == .video(.segment))
        #expect(FrameKind(rawKind: nil) != .surrogate)
        #expect(FrameKind(rawKind: "") == .other(""))
        #expect(FrameKind(rawKind: "").storageValue == nil)
    }

    @Test
    func unknownStoredKindsMapToOtherAndSurviveResaveUnchanged() {
        let unknowns = ["mystery_kind_v2", "future.kind", "SURROGATE", "surrogate "]
        for unknown in unknowns {
            let parsed = FrameKind(rawKind: unknown)
            guard case .other(let raw) = parsed else {
                Issue.record("expected .other for \(unknown)")
                continue
            }
            #expect(raw == unknown)
            #expect(FrameKind(rawKind: unknown).storageValue == unknown)
        }
        #expect(FrameKind(rawKind: nil) == FrameKind(rawKind: nil))
        #expect(FrameKind(rawKind: nil).storageValue == nil)
    }

    @Test
    func switchOverCasesIsExhaustiveWithoutDefault() {
        let allCases: [FrameKind] = [
            .surrogate,
            .handoff,
            .photo(.root),
            .video(.segment),
            .other("custom"),
        ]
        for kind in allCases {
            switch kind {
            case .surrogate:
                #expect(kind.storageValue == "surrogate")
            case .handoff:
                #expect(kind.storageValue == "handoff")
            case .photo:
                #expect(kind.storageValue?.hasPrefix("photo") == true || kind.storageValue?.hasPrefix("system.photos.") == true)
            case .video:
                #expect(kind.storageValue?.hasPrefix("video.") == true)
            case .other:
                break
            }
        }
    }
}
