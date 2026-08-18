#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif
import SwiftUI
import Wax

struct PhotoThumbnailView: View {
    let pixel: PhotoPixel?

    var body: some View {
        if let pixel, let image = Self.image(from: pixel.data) {
            image
                .resizable()
                .scaledToFill()
                .frame(width: 64, height: 64)
                .clipShape(.rect(cornerRadius: 8))
                .accessibilityHidden(true)
        } else {
            Image(systemName: "photo")
                .font(.title2)
                .foregroundStyle(.secondary)
                .frame(width: 64, height: 64)
                .background(.fill.tertiary, in: RoundedRectangle(cornerRadius: 8))
                .accessibilityHidden(true)
        }
    }

    private static func image(from data: Data) -> Image? {
        #if canImport(UIKit)
        guard let uiImage = UIImage(data: data) else { return nil }
        return Image(uiImage: uiImage)
        #elseif canImport(AppKit)
        guard let nsImage = NSImage(data: data) else { return nil }
        return Image(nsImage: nsImage)
        #else
        nil
        #endif
    }
}
