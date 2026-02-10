Prompt:
Implement PDF ingestion for MemoryOrchestrator using PDFKit text extraction, per plan. Tests already exist.

Goal:
Add PDFIngestError, PDFTextExtractor, and MemoryOrchestrator.remember(pdfAt:metadata:) that feeds into remember(_ content:).

Task Breakdown:
- Add Sources/Wax/Ingest/PDFIngestError.swift
- Add Sources/Wax/Ingest/PDFTextExtractor.swift (PDFKit-gated)
- Add Sources/Wax/Orchestrator/MemoryOrchestrator+PDF.swift (PDFKit-gated)
- Ensure extraction runs in detached Task
- Merge metadata with reserved keys overriding user entries

Expected Output:
- Production code changes implementing PDF ingestion with no unrelated edits.
