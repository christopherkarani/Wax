import PhotosUI
import SwiftUI

struct PhotoLibraryPicker: View {
    @Binding var selection: [PhotosPickerItem]
    var isEnabled: Bool

    var body: some View {
        PhotosPicker(
            selection: $selection,
            maxSelectionCount: 10,
            matching: .images,
            photoLibrary: .shared()
        ) {
            Label("Choose photos", systemImage: "photo.on.rectangle")
        }
        .disabled(!isEnabled)
    }
}
