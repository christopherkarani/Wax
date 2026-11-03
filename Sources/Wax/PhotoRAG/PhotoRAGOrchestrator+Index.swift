#if canImport(ImageIO)
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers
import WaxCore
import WaxVectorSearch

#if canImport(Photos)
@preconcurrency import Photos
#endif

#if canImport(CoreLocation)
import CoreLocation
#endif

extension PhotoRAGOrchestrator {
    // MARK: - Indexing

    func rebuildIndex() async throws {
        let metas = await wax.frameMetas()

        var supersededRoots: Set<UInt64> = []
        supersededRoots.reserveCapacity(64)
        for meta in metas where FrameKind(rawKind: meta.kind) == .photo(.root) {
            if meta.supersededBy != nil {
                supersededRoots.insert(meta.id)
            }
        }

        var next = IndexState()
        var retiredVectorIds: Set<UInt64> = []

        for meta in metas {
            guard meta.status != .deleted else {
                retiredVectorIds.insert(meta.id)
                continue
            }
            guard let kind = meta.kind else { continue }
            if !kind.hasPrefix("photo.") && FrameKind(rawKind: kind) != .photo(.syncState) { continue }
            guard let entries = meta.metadata?.entries,
                  let photoID = Self.photoID(from: entries)
            else { continue }

            if FrameKind(rawKind: kind) == .photo(.root) {
                guard meta.supersededBy == nil else {
                    retiredVectorIds.insert(meta.id)
                    continue
                }
                next.rootByPhotoID[photoID] = meta.id
                next.photoIDByRoot[meta.id] = photoID
            }

            if let parentId = meta.parentId {
                guard !supersededRoots.contains(parentId) else {
                    retiredVectorIds.insert(meta.id)
                    continue
                }
                var refs = next.derivedByRoot[parentId] ?? DerivedRefs()
                switch FrameKind(rawKind: kind) {
                case .photo(.ocrSummary):
                    refs.ocrSummary = meta.id
                case .photo(.captionShort):
                    refs.caption = meta.id
                case .photo(.tags):
                    refs.tags = meta.id
                case .photo(.region):
                    refs.regions.append(meta.id)
                case .photo(.ocrBlock):
                    refs.ocrBlocks.append(meta.id)
                default:
                    break
                }
                next.derivedByRoot[parentId] = refs
            }

            if Self.isSearchablePhotoKind(kind),
               let bin = Self.locationBin(from: entries) {
                next.locationBins[bin, default: []].insert(meta.id)
                next.locationByFrame[meta.id] = Self.locationCoordinate(from: entries)
            }
        }

        index = next
        await sweepRetiredVectors(retiredVectorIds)
    }

    /// Removes vectors and text postings for frames outside the live index
    /// (superseded trees, deleted frames). Best-effort: a sweep failure must not
    /// block opening or reindexing the store.
    private func sweepRetiredVectors(_ frameIds: Set<UInt64>) async {
        guard !frameIds.isEmpty else { return }
        for frameId in frameIds {
            do {
                try await session.removeVector(frameId: frameId)
            } catch {
                WaxDiagnostics.logSwallowed(
                    error,
                    context: "PhotoRAG retired-vector sweep",
                    fallback: "stale vector may remain in the committed index"
                )
            }
            do {
                try await session.removeText(frameId: frameId)
            } catch {
                WaxDiagnostics.logSwallowed(
                    error,
                    context: "PhotoRAG retired-text sweep",
                    fallback: "stale text posting may remain in the committed index"
                )
            }
        }
    }

    private static func isSearchablePhotoKind(_ kind: String) -> Bool {
        switch FrameKind(rawKind: kind) {
        case .photo(.root), .photo(.ocrSummary), .photo(.captionShort), .photo(.tags), .photo(.region):
            return true
        default:
            return false
        }
    }

    // MARK: - Location allowlist

    func buildLocationAllowlist(location: PhotoLocationQuery) -> Set<UInt64>? {
        let center = location.center
        let radius = location.radiusMeters

        guard radius > 0 else { return nil }

        let lat = center.latitude
        let lon = center.longitude

        // 111,000 meters ≈ 1 degree of latitude (standard geodetic approximation).
        let latDelta = radius / 111_000.0
        // Cap lonDelta to 180 degrees to prevent unbounded expansion near poles.
        // cos(lat) adjusts for longitude convergence; max(1e-6, ...) prevents division by zero at poles.
        let lonDelta = min(180.0, radius / max(1e-6, 111_000.0 * cos(lat * .pi / 180)))

        let minLat = lat - latDelta
        let maxLat = lat + latDelta
        let minLon = lon - lonDelta
        let maxLon = lon + lonDelta

        // Clamp latitude bins to valid range (-90..90 -> bins -9000..9000).
        let minLatBin = max(-9000, Int(floor(minLat * 100.0)))
        let maxLatBin = min(9000, Int(floor(maxLat * 100.0)))

        let lonRanges = Self.longitudeBinRanges(minLon: minLon, maxLon: maxLon, lonDelta: lonDelta)

        // Compute total bin count. If the search area is degenerate (too many bins),
        // return nil to gracefully degrade to "no location filter".
        let latBinCount = maxLatBin - minLatBin + 1
        let lonBinCount = lonRanges.reduce(0) { partial, range in
            partial + (range.upperBound - range.lowerBound + 1)
        }

        guard latBinCount > 0, lonBinCount > 0 else { return nil }
        // Degenerate guard: if the search area is too large (>100k bins, ~radius >5000km),
        // skip location filtering entirely and let the query proceed without spatial constraint.
        guard latBinCount * lonBinCount < 100_000 else { return nil }

        var allowlist: Set<UInt64> = []

        for latBin in minLatBin...maxLatBin {
            for lonRange in lonRanges {
                for lonBin in lonRange {
                    let bin = LocationBin(latBin: latBin, lonBin: lonBin)
                    if let ids = index.locationBins[bin] {
                        for id in ids {
                            guard let coordinate = index.locationByFrame[id] else { continue }
                            if Self.distanceMeters(from: center, to: coordinate) <= radius {
                                allowlist.insert(id)
                            }
                        }
                    }
                }
            }
        }
        return allowlist
    }

    private static func longitudeBinRanges(minLon: Double, maxLon: Double, lonDelta: Double) -> [ClosedRange<Int>] {
        guard lonDelta < 180 else {
            return [-18000...18000]
        }

        if minLon < -180 {
            let wrappedMin = Int(floor((minLon + 360.0) * 100.0))
            let maxBin = Int(floor(maxLon * 100.0))
            return [max(-18000, wrappedMin)...18000, -18000...min(18000, maxBin)]
        }

        if maxLon > 180 {
            let minBin = Int(floor(minLon * 100.0))
            let wrappedMax = Int(floor((maxLon - 360.0) * 100.0))
            return [max(-18000, minBin)...18000, -18000...min(18000, wrappedMax)]
        }

        let minBin = max(-18000, Int(floor(minLon * 100.0)))
        let maxBin = min(18000, Int(floor(maxLon * 100.0)))
        return [minBin...maxBin]
    }

    static func photoID(from entries: [String: String]) -> PhotoID? {
        guard let id = entries[MetaKey.assetID] else { return nil }
        return PhotoID.fromMetadata(id: id, source: entries[MetaKey.source])
    }

    private static func locationBin(from meta: [String: String]) -> LocationBin? {
        guard let latStr = meta[MetaKey.lat],
              let lonStr = meta[MetaKey.lon],
              let lat = Double(latStr),
              let lon = Double(lonStr)
        else { return nil }
        return LocationBin(latBin: Int(floor(lat * 100.0)), lonBin: Int(floor(lon * 100.0)))
    }

    private static func locationCoordinate(from meta: [String: String]) -> PhotoCoordinate? {
        guard let latStr = meta[MetaKey.lat],
              let lonStr = meta[MetaKey.lon],
              let lat = Double(latStr),
              let lon = Double(lonStr)
        else { return nil }
        return PhotoCoordinate(latitude: lat, longitude: lon)
    }

    private static func distanceMeters(from lhs: PhotoCoordinate, to rhs: PhotoCoordinate) -> Double {
        let earthRadiusMeters = 6_371_000.0
        let lat1 = lhs.latitude * .pi / 180
        let lat2 = rhs.latitude * .pi / 180
        let deltaLat = (rhs.latitude - lhs.latitude) * .pi / 180
        let deltaLon = (rhs.longitude - lhs.longitude) * .pi / 180

        let a = sin(deltaLat / 2) * sin(deltaLat / 2)
            + cos(lat1) * cos(lat2) * sin(deltaLon / 2) * sin(deltaLon / 2)
        let c = 2 * atan2(sqrt(a), sqrt(max(0, 1 - a)))
        return earthRadiusMeters * c
    }
}

#endif // canImport(ImageIO)
