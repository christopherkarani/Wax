import Foundation

/// Search holds keep postings out of sight until the frames they point at are committed.
///
/// A frame import (``WaxCore/Wax/beginFrameImport()``) indexes its frames' text before its
/// single commit, and its frames are unknown to readers until that commit. Between the two a
/// search could rank those frames and lose the hits it should return. The import holds
/// searches across that window: ``holdSearches()`` waits for the searches already running,
/// then new ones wait until ``releaseSearches()``.
extension FTS5SearchEngine {
    /// Waits for running searches to finish, then makes new searches wait until
    /// ``releaseSearches()``. Holds nest; each needs its own release.
    package func holdSearches() async {
        searchHolds += 1
        while searchesInFlight > 0 {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                searchDrainWaiters.append(continuation)
            }
        }
    }

    /// Ends a ``holdSearches()``; searches resume once no hold is left.
    package func releaseSearches() {
        guard searchHolds > 0 else { return }
        searchHolds -= 1
        guard searchHolds == 0 else { return }
        let waiters = searchHoldReleaseWaiters
        searchHoldReleaseWaiters = []
        for waiter in waiters {
            waiter.resume()
        }
    }

    /// Searches waiting for a hold to end. Tests only.
    package func searchesWaitingOnHoldForTesting() -> Int {
        searchHoldReleaseWaiters.count
    }

    /// Internal only because of the file split.
    func beginSearch() async {
        while searchHolds > 0 {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                searchHoldReleaseWaiters.append(continuation)
            }
        }
        searchesInFlight += 1
    }

    /// Internal only because of the file split.
    func endSearch() {
        searchesInFlight -= 1
        guard searchesInFlight == 0 else { return }
        let waiters = searchDrainWaiters
        searchDrainWaiters = []
        for waiter in waiters {
            waiter.resume()
        }
    }
}
