import SwiftUI

struct SearchScreen: View {
    @State private var model = DemoSearchModel()
    @State private var queryTask: Task<Void, Never>?

    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                Picker("Mode", selection: $model.mode) {
                    ForEach(DemoMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .disabled(model.isBusy)

                TextField(model.mode.placeholder, text: $model.query)
                    .textFieldStyle(.roundedBorder)
                    #if os(iOS)
                    .textInputAutocapitalization(.never)
                    #endif
                    .autocorrectionDisabled()
                    .submitLabel(.search)
                    .onSubmit(submitQuery)

                HStack {
                    Text(model.loadCaption)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Search", action: submitQuery)
                        .disabled(model.isBusy || model.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }

                if let notice = model.notice {
                    Text(notice)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                resultsPane
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                if model.mode == .photos {
                    GroundedAnswerView(text: model.answer, isStreaming: model.isGenerating)
                }

                StatusFooter(
                    sizeLabel: model.storeSizeLabel,
                    fmStatus: model.fmStatus,
                    photoStoreURL: model.storeURL,
                    canShareFile: model.storeBytes != nil
                )
            }
            .padding()
            .navigationTitle("Wax")
            .task {
                model.refreshFoundationModelsStatus()
                await model.prepareCurrentSection()
            }
            .onChange(of: model.mode) { _, _ in
                queryTask?.cancel()
                queryTask = Task { await model.prepareCurrentSection() }
            }
        }
    }

    @ViewBuilder
    private var resultsPane: some View {
        switch model.mode {
        case .vector:
            TextResultsPane(
                hits: model.textHits,
                emptyTitle: "Vector search",
                emptyBody: "Harbor notes and PDFs load automatically. Try a paraphrase, not a filename."
            )
        case .files:
            TextResultsPane(
                hits: model.textHits,
                emptyTitle: "File RAG",
                emptyBody: "Markdown and PDFs from the Harbor week load when you open this section."
            )
        case .photos:
            PhotoResultsPane(hits: model.photoHits, isPermissionBlocked: false, notice: model.notice)
        case .videos:
            VideoResultsPane(hits: model.videoHits)
        }
    }

    private func submitQuery() {
        queryTask?.cancel()
        queryTask = Task { await model.search() }
    }
}

#Preview {
    SearchScreen()
}
