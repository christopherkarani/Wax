# North Harbor demo corpus

Thirty original workshop artifacts for recording Wax retrieval: **10 photos**, **10 videos**, **10 files** (6 markdown, 4 PDF). They share one week of facts so a query can land on more than one surface.

Theme: Harbor Workshop, week of 10–15 Aug 2026. Local store name on the tape: `harbor-week.wax`.

Regenerate:

```bash
uv run --with pillow --python python3.12 python scripts/generate_corpus.py
```

## Why this set

StressLab serial plates prove OCR. They look like a harness on camera. These files are meant to be dropped into the demo and searched like a real local pile: a whiteboard, a nameplate, a coffee receipt, notes, invoices, and short voice clips.

Wax does not transcribe in v1. Each video has a sidecar under `transcripts/` with `start_ms` / `end_ms` / `text`. Point a host `VideoTranscriptProvider` at that folder and map `localFileURL`’s basename to the matching JSON.

```bash
open Examples/WaxDemoCorpus
```

## Demo beats

| Surface | Query | Should surface |
| --- | --- | --- |
| Photo RAG | `WAX-HB-4419` | nameplate, spec PDF, bench clip |
| Photo RAG | `Fog Latte` | receipt, invoice, coffee clip |
| File RAG | `what is the offline policy` | offline-policy.md, week report, voice memo |
| File RAG | `PO-NH-8821` | shipping label, PO PDF, unbox clip |
| Video RAG | `when do we ship` | standup + whiteboard clips |
| Video RAG | `bench radio serial` | bench clip |
| Vector | `how do we keep memory on the device` | policy, changelog, voice memo, paraphrase clip |
| Cross | `Mira Chen` | card, standup note, flush clip |
| Cross | `ANE-7 cooling plate` | label, PO, unbox |
| Close | `harbor-week.wax` | MiniLM error still, policy, flush clip |

Full catalog: `manifest.json`.

## Ingest notes

- Photos: local `PhotoFile` ingest. OCR must read the serials as their own blocks (`WAX-HB-4419`, `PO-NH-8821`, `NH-19`, `LOT NH-17`).
- Files: markdown through `remember(fileAt:)`; PDFs through `remember(pdfAt:)`.
- Videos: local `VideoFile` ingest plus the JSON transcripts. Clips are 720p still+voice, about 8–12s.
- Vector: do not type a filename. Use the paraphrase in the table.

These assets are original generated fixtures for the example, not stock photography.
