import SwiftUI

struct EmptyResultsView: View {
    var surface: PhotoIngestSurface = .current

    var body: some View {
        ContentUnavailableView(
            PhotoIngestCopy.emptyStateTitle(surface: surface),
            systemImage: "photo.on.rectangle.angled",
            description: Text(PhotoIngestCopy.emptyStateBody(surface: surface))
        )
    }
}
