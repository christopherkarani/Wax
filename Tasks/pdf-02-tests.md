Prompt:
Add fixtures and failing Swift Testing tests for PDF ingestion. Do not implement PDF ingestion code in this task.

Goal:
Introduce PDF fixtures and tests that fail until PDF ingestion is implemented.

Task Breakdown:
- Add two PDF fixtures under Tests/WaxIntegrationTests/Fixtures:
  - pdf_fixture_text.pdf (2 pages with unique phrases)
  - pdf_fixture_blank.pdf (no extractable text)
- Create Tests/WaxIntegrationTests/PDFIngestTests.swift with:
  - Ingest + recall works (text-only)
  - Metadata propagates to document + chunks
  - Blank PDF throws PDFIngestError.noExtractableText
  - Missing file throws PDFIngestError.fileNotFound
- Guard tests with #if canImport(PDFKit)

Expected Output:
- New fixture files and test file only. No production code changes.
