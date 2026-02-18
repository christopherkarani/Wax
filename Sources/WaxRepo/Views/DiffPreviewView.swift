#if WaxRepo && os(macOS)
import SwiftTUI

/// An indexed diff line for unique ForEach identification.
private struct DiffLine: Hashable {
    let index: Int
    let text: String

    func hash(into hasher: inout Hasher) {
        hasher.combine(index)
    }

    static func == (lhs: DiffLine, rhs: DiffLine) -> Bool {
        lhs.index == rhs.index
    }
}

/// Colored diff preview pane.
///
/// Lines are colored according to standard diff conventions:
/// - `+` additions in green
/// - `-` deletions in red
/// - `@@` hunk headers in cyan
/// - `commit` / `diff --git` headers in yellow
struct DiffPreviewView: View {
    let diff: String

    var body: some View {
        VStack {
            if diff.isEmpty {
                Text("Select a commit to preview its diff")
                    .foregroundColor(.gray)
            } else {
                VStack(alignment: .leading) {
                    ForEach(diffLines, id: \.index) { line in
                        Text(line.text)
                            .foregroundColor(lineColor(for: line.text))
                    }
                }
            }
        }
    }

    private var diffLines: [DiffLine] {
        diff.components(separatedBy: "\n")
            .prefix(200)
            .enumerated()
            .map { DiffLine(index: $0.offset, text: $0.element) }
    }

    private func lineColor(for line: String) -> Color {
        if line.hasPrefix("+") { return .green }
        if line.hasPrefix("-") { return .red }
        if line.hasPrefix("@@") { return .cyan }
        if line.hasPrefix("commit ") || line.hasPrefix("diff --git") { return .yellow }
        if line.hasPrefix("Author:") || line.hasPrefix("Date:") { return .magenta }
        return .default
    }
}
#endif
