import Foundation
import WaxCore

extension MemoryOrchestrator {
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
        let stats = await wax.stats()
        var documentMetas: [FrameMeta] = []
        documentMetas.reserveCapacity(Int(stats.frameCount))

        for frameID in 0..<stats.frameCount {
            let meta = try await wax.frameMeta(frameId: frameID)
            if meta.status == .active && meta.role == .document && meta.payloadLength > 0 {
                documentMetas.append(meta)
            }
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
}
