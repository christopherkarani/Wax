import Foundation
import WaxCore

extension MemoryOrchestrator {
    package struct CorpusTargetDocument: Equatable, Sendable {
        package var timestampMs: Int64
        package var text: String
        package var metadata: [String: String]

        package init(timestampMs: Int64, text: String, metadata: [String: String]) {
            self.timestampMs = timestampMs
            self.text = text
            self.metadata = metadata
        }
    }

    package struct CorpusSourceDocument: Equatable, Sendable {
        package var frameId: UInt64
        package var timestampMs: Int64
        package var kind: String?
        package var role: FrameRole
        package var text: String
        package var metadata: [String: String]

        package init(
            frameId: UInt64,
            timestampMs: Int64,
            kind: String?,
            role: FrameRole,
            text: String,
            metadata: [String: String]
        ) {
            self.frameId = frameId
            self.timestampMs = timestampMs
            self.kind = kind
            self.role = role
            self.text = text
            self.metadata = metadata
        }
    }

    package func corpusSourceDocuments() async throws -> [CorpusSourceDocument] {
        let frameMetas = await wax.frameMetas()
        var documentMetas: [FrameMeta] = []
        documentMetas.reserveCapacity(frameMetas.count)

        for meta in frameMetas where meta.status == .active && meta.role == .document && meta.payloadLength > 0 {
            documentMetas.append(meta)
        }

        let contentsByID = try await wax.frameContents(frameIds: documentMetas.map(\.id))
        var documents: [CorpusSourceDocument] = []
        documents.reserveCapacity(documentMetas.count)

        for meta in documentMetas {
            guard let data = contentsByID[meta.id],
                  let text = String(data: data, encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines),
                  !text.isEmpty else {
                continue
            }

            documents.append(
                CorpusSourceDocument(
                    frameId: meta.id,
                    timestampMs: meta.timestamp,
                    kind: meta.kind,
                    role: meta.role,
                    text: text,
                    metadata: meta.metadata?.entries ?? [:]
                )
            )
        }

        return documents
    }

    package func canonicalDocumentFrameID(for frameID: UInt64) async throws -> UInt64 {
        let meta = try await wax.frameMetaIncludingPending(frameId: frameID)
        if meta.role == .chunk, let parentID = meta.parentId {
            return parentID
        }
        return frameID
    }

    package func ingestCorpusDocumentsTextOnly(_ documents: [CorpusTargetDocument]) async throws {
        guard !documents.isEmpty else {
            return
        }

        let texts = documents.map(\.text)
        let contents = texts.map { Data($0.utf8) }
        let timestampsMs = documents.map(\.timestampMs)
        let options: [FrameMetaSubset] = documents.map { document in
            var option = FrameMetaSubset(
                role: .document,
                metadata: Metadata(document.metadata)
            )
            option.searchText = document.text
            return option
        }

        let frameIds = try await session.putBatch(
            contents: contents,
            options: options,
            timestampsMs: timestampsMs
        )
        if config.enableTextSearch {
            try await session.indexTextBatch(frameIds: frameIds, texts: texts)
        }
    }
}
