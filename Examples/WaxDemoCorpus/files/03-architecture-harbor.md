# Harbor retrieval architecture

Four surfaces, one local store.

| Surface | Ingest | Query that should land |
| --- | --- | --- |
| Vector search | markdown + PDF text | "how do we keep memory on the device" |
| File RAG | UTF-8 notes + PDFKit text | "offline policy", "Fog Latte" |
| Photo RAG | local images + Vision OCR | `WAX-HB-4419`, `PO-NH-8821` |
| Video RAG | mp4 + host transcripts | "ship Friday", "bench radio serial" |

Hybrid search blends MiniLM vectors with BM25. Identifier-like queries
(serials, PO numbers) must stay factual so the unique token wins.

Photo RAG and Video RAG are package APIs used by the example app. File
ingest is `remember(fileAt:)` for markdown and `remember(pdfAt:)` for PDFs.

