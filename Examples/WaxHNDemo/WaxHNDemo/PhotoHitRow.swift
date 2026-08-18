import SwiftUI
import Wax

struct PhotoHitRow: View {
    let item: PhotoRAGItem

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            PhotoThumbnailView(pixel: item.thumbnail)
            VStack(alignment: .leading, spacing: 4) {
                Text(item.summaryText)
                    .font(.body)
                    .lineLimit(3)
                Text(item.assetID)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .textSelection(.enabled)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(item.summaryText), asset \(item.assetID)")
    }
}
