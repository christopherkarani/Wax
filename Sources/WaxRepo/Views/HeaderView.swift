#if WaxRepo && os(macOS)
import SwiftTUI

/// Top bar showing the wax-repo branding and search input.
struct HeaderView: View {
    let query: String
    let isSearching: Bool
    let onSearch: (String) -> Void

    var body: some View {
        VStack {
            HStack {
                Text("wax-repo")
                    .bold()
                    .foregroundColor(.yellow)
                Text(" | semantic git search")
                    .foregroundColor(.gray)
            }
            HStack {
                Text(isSearching ? "[searching...]" : "[enter query]")
                    .foregroundColor(.gray)
                TextField(placeholder: "search commits...", action: onSearch)
            }
            Divider()
        }
    }
}
#endif
