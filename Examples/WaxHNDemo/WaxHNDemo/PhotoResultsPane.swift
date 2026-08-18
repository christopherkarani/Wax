import SwiftUI
import Wax

struct PhotoResultsPane: View {
    let hits: [PhotoRAGItem]
    let isPermissionBlocked: Bool
    let notice: String?

    var body: some View {
        if !hits.isEmpty {
            List(hits) { item in
                PhotoHitRow(item: item)
            }
            .listStyle(.plain)
        } else if isPermissionBlocked, let notice {
            ContentUnavailableView(
                "Photos access needed",
                systemImage: "photo.badge.exclamationmark",
                description: Text(notice)
            )
        } else {
            EmptyResultsView()
        }
    }
}
