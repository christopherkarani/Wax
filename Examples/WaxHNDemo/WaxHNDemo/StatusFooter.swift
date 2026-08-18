import SwiftUI

struct StatusFooter: View {
    var sizeLabel: String
    var fmStatus: String
    var photoStoreURL: URL
    var canShareFile: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(PhotoStoreChrome.statusLine(size: sizeLabel, fmStatus: fmStatus))
            Text(PhotoStoreChrome.honestLine)
            PhotoStoreShareBar(photoStoreURL: photoStoreURL, isEnabled: canShareFile)
        }
        .font(.footnote)
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            "\(PhotoStoreChrome.statusLine(size: sizeLabel, fmStatus: fmStatus)). \(PhotoStoreChrome.honestLine)"
        )
    }
}
