import SwiftUI

struct ICloudIngestBanner: View {
    let report: PhotoIngestReport
    var surface: PhotoIngestSurface = .current

    var body: some View {
        Label {
            VStack(alignment: .leading, spacing: 4) {
                Text(PhotoIngestCopy.bannerTitle(for: report))
                    .font(.headline)
                Text(PhotoIngestCopy.bannerBody(for: report, surface: surface))
            }
        } icon: {
            Image(systemName: "exclamationmark.triangle.fill")
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(.orange)
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.orange.opacity(0.15), in: RoundedRectangle(cornerRadius: 8))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            "\(PhotoIngestCopy.bannerTitle(for: report)). \(PhotoIngestCopy.bannerBody(for: report, surface: surface))"
        )
    }
}
