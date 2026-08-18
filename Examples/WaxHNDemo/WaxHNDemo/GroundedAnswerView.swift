import SwiftUI

struct GroundedAnswerView: View {
    let text: String
    let isStreaming: Bool

    var body: some View {
        if text.isEmpty && !isStreaming {
            EmptyView()
        } else {
            VStack(alignment: .leading, spacing: 6) {
                Text("On-device answer")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                if text.isEmpty {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Text(text)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                }
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel(text.isEmpty ? "Generating on-device answer" : text)
        }
    }
}
