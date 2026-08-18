#if os(macOS)
import AppKit
#endif
import SwiftUI

struct PhotoStoreShareBar: View {
    let photoStoreURL: URL
    var isEnabled: Bool

    var body: some View {
        HStack {
            #if os(macOS)
            Button("Reveal in Finder", systemImage: "folder", action: revealInFinder)
                .disabled(!isEnabled)
            #endif
            if isEnabled {
                ShareLink(item: photoStoreURL) {
                    Label("Share", systemImage: "square.and.arrow.up")
                }
            }
        }
    }

    #if os(macOS)
    private func revealInFinder() {
        NSWorkspace.shared.activateFileViewerSelecting([photoStoreURL])
    }
    #endif
}
