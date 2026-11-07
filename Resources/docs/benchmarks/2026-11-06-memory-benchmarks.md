# Wax memory benchmarks, November 2026

Retrieval, end-to-end QA, and systems results for Wax on branch
`feat/metalanns-0.4-benchmarks` (MetalANNS 0.4.0). Every number here comes from the
harness in [`Benchmarks/`](../../../Benchmarks/README.md), which documents how to reproduce it.

## Summary

| Benchmark | Metric | Wax | Best reference | Before fixes |
|---|---|---|---|---|
| LoCoMo retrieval | R_all@5 / @10 | **0.537 / 0.618** (hybrid, Arctic) | Contriever 0.407 / 0.494 | 0.186 / 0.294 |
| LoCoMo QA | LLM judge J | **70.4%** (hybrid, Arctic, top 30); 64.9% with MiniLM | Contriever top 30: 62.4% | 56.3% (vector, top 30) |
| LongMemEval-S retrieval | R_all@5 / NDCG@10 | 0.883 / 0.917 (hybrid, MiniLM) | **Contriever 0.902 / 0.927** | 0.742 / – |
| LongMemEval-S QA | accuracy | 86.0% (hybrid, MiniLM, top 5) | **Contriever top 5: 87.8%** | 83.0% (vector, top 5) |
| Systems, 100k passages | vector recall@10 | **0.998** | Chroma HNSW 0.976 | 0.902 |
| Systems, 100k passages | disk | 395 MB | Chroma 408 MB (text + vectors) | 13.5 GB |
| Systems, 100k passages | vector p95 | 4.4 ms | Chroma HNSW 1.4 ms | 64–97 ms |
| Systems, 100k passages | cold open + first query | 482 ms | Chroma HNSW 384 ms | 840 ms |

Wax leads LoCoMo on retrieval and QA. On LongMemEval it is 1.9 points behind Contriever
in retrieval and 1.8 points behind in QA, using a model one fifth the size (MiniLM-L6,
22M parameters, against Contriever's 110M). With Contriever embeddings it ties bare
Contriever on LongMemEval, and adds 8 points on LoCoMo (see
[Same-model comparison](#same-model-comparison)).

## Setup

- Machine: Apple M3 Max (14 cores, 36 GB), macOS 27.0. Other workloads were running (load average 30–57
  during the systems runs), so treat latency and throughput as indicative.
- Wax is driven through the public `Memory` API only: one fresh store per question, the
  default chunking for the embedder, `Memory.search` with hybrid, vector or text mode.
- Embedders: Wax's bundled on-device models, all-MiniLM-L6-v2 (default) and Snowflake
  Arctic Embed (CoreML). Reference retrievers run in Python on the same corpora:
  BM25, BM25 with normalized text, all-MiniLM-L6-v2, and Contriever (`facebook/contriever`,
  mean pooling, dot product). Stella was skipped: it requires `trust_remote_code`.
- QA reader: `claude-haiku-5-5`. Judge: `claude-sonnet-5-5`. Both run through `claude -p`
  with no tools or settings. Scores are comparable across rows of this report, but not to
  papers that used GPT-4o readers.

## LongMemEval-S retrieval

Official protocol (LongMemEval `src/retrieval`, commit 9e0b455f), session level,
419 scored questions.

| Retriever | R_all@5 | R_all@10 | NDCG@10 |
|---|---|---|---|
| Contriever | **0.902** | **0.971** | **0.927** |
| Wax hybrid, e5-small-v2, text weight 0.4 | 0.900 | 0.967 | **0.927** |
| Wax hybrid, e5-small-v2 | 0.885 | 0.957 | 0.924 |
| Wax hybrid, MiniLM | 0.883 | 0.950 | 0.917 |
| Wax hybrid, Arctic | 0.878 | 0.940 | 0.899 |
| Wax vector, MiniLM | 0.869 | 0.947 | 0.892 |
| MiniLM | 0.852 | 0.938 | 0.878 |
| Wax text | 0.828 | 0.893 | 0.875 |
| BM25 | 0.742 | 0.823 | – |
| Wax hybrid, MiniLM, before fixes | 0.742 | 0.840 | – |

Per question type, Wax hybrid beats Contriever on knowledge-update (R_all@5 1.000
against 0.944) and is within 3.3 points on the single-session and temporal types. The
gap is multi-session questions, where the evidence is spread over several sessions
(0.760 against 0.851). Fusing Wax's own text and vector rankings offline peaks near 0.88,
so the remaining gap comes from the embedder rather than from ranking.

### Embedder choice

Small embedders were scored through Wax hybrid search before any was converted to Core
ML. On LongMemEval R_all@5: MiniLM 0.883, gte-small 0.883, e5-small-v2 0.883, bge-small
0.885, bge-base 0.888. None beat Contriever by default. e5-small-v2 with the text weight
lowered to 0.4 (`.hybrid(alpha: 0.4)`) reaches 0.900, against Contriever's 0.902, and
keeps the LoCoMo lead (0.503). It ships as the opt-in `E5Embeddings` trait
(`7b1892861`); MiniLM stays the default. The e5 rows above come from the bundled Core ML
model, whose embeddings match PyTorch to a cosine of at least 0.9996 on 215 texts.

A rule that picked the text weight from the corpus's median document length scored
0.912 on LongMemEval but failed a held-out check (LongMemEval turn level), so it was not
shipped.

## LoCoMo retrieval

Mem0's evaluation protocol (commit aae5989e), categories 1–4: 1,540 questions, of which
the 1,535 with evidence turns are scored. R_all@k: every evidence turn is in the top k.

| Retriever | R_all@5 | R_all@10 | R_all@30 |
|---|---|---|---|
| Wax hybrid, Arctic | **0.537** | **0.618** | **0.725** |
| Wax vector, Arctic | 0.509 | 0.586 | 0.717 |
| Wax hybrid, e5-small-v2 | 0.509 | 0.579 | 0.687 |
| Wax hybrid, e5-small-v2, text weight 0.4 | 0.503 | 0.583 | 0.690 |
| Wax hybrid, MiniLM | 0.466 | 0.550 | 0.665 |
| Wax text | 0.429 | 0.495 | 0.586 |
| Contriever | 0.407 | 0.494 | – |
| BM25, normalized | 0.399 | 0.469 | – |
| Wax vector, MiniLM | 0.372 | 0.429 | – |
| MiniLM | 0.326 | 0.406 | – |
| BM25 | 0.277 | 0.339 | – |
| Wax hybrid, MiniLM, before fixes | 0.186 | 0.294 | 0.484 |

Temporal questions (category 2), Wax hybrid MiniLM, R_all@10: 0.103 before, 0.647 after.

## Same-model comparison

To separate the Wax pipeline from the embedding model, Wax was run on Contriever
vectors served by `Benchmarks/scripts/embed_server.py`.

| Benchmark | Bare Contriever | Wax vector | Wax hybrid |
|---|---|---|---|
| LongMemEval R_all@5 (dot product) | 0.902 | **0.905** | 0.897 |
| LongMemEval NDCG@10 (dot product) | 0.927 | 0.925 | **0.932** |
| LoCoMo R_all@5 (dot product) | 0.407 | 0.408 | **0.490** |
| LoCoMo R_all@5 (cosine, as Wax ships) | – | 0.282 | 0.443 |
| LongMemEval R_all@5 (cosine, as Wax ships) | 0.754 | 0.776 | 0.878 |

Contriever was trained for dot product. Before `82cd29e13`, `Memory` always ranked
vectors by cosine, which cost a dot-product model 15 points on LongMemEval. Embedders now
declare `similarity: .dotProduct` (the default stays `.cosine`); the bench passes
`--embedder-similarity dot`. The dot-product rows come from the branch build. Wax's
bundled MiniLM and Arctic models are cosine models and are unaffected.

## End-to-end QA

### LongMemEval-S (500 questions)

| Context | Accuracy | Task-averaged |
|---|---|---|
| Oracle (evidence sessions only) | 93.4% | 95.9% |
| Contriever top 5 | **87.8%** | **90.0%** |
| Wax hybrid MiniLM top 5 | 86.0% | 88.2% |
| Wax vector MiniLM top 5, before fixes | 83.0% | 84.8% |

Wax hybrid beats Contriever on knowledge-update (95.8% against 90.3%) and abstention
(90.0% against 83.3%), ties on single-session user facts (95.3%), and is within 3.3 points
on the other single-session and temporal types. It trails on multi-session (69.4%
against 78.5%), which follows the retrieval gap above.

### LoCoMo (1,540 questions)

| Context | J | F1 | Multi-hop | Temporal | Open-domain | Single-hop |
|---|---|---|---|---|---|---|
| Full conversation | **76.6%** | 0.461 | 67.4% | 70.1% | 52.1% | 85.0% |
| Wax hybrid Arctic top 30 | 70.4% | **0.471** | 55.7% | 61.1% | 51.0% | 81.1% |
| Wax hybrid MiniLM top 30 | 64.9% | 0.445 | 43.6% | 58.3% | 46.9% | 76.7% |
| Contriever top 30 | 62.4% | 0.435 | 48.6% | 52.6% | 49.0% | 72.3% |
| Wax vector MiniLM top 30, before fixes | 56.3% | 0.383 | 39.0% | 51.1% | 44.8% | 65.4% |

## Systems

MS MARCO passages with precomputed all-MiniLM-L6-v2 vectors, 1,000 queries,
recall@10 against exact search. Wax ingests through `Memory.save` with no manual flush;
the competitors bulk-load. Wax's disk figure includes the text, the full-text index and
metadata; most competitors store vectors only.

| System | N | Ingest docs/s | Disk MB | Cold open + 1st query ms | Vector p50 / p95 ms | Recall@10 |
|---|---|---|---|---|---|---|
| Wax | 10,000 | 3,401 | 53 | 81 | 2.23 / 2.81 | 0.998 |
| Chroma HNSW | 10,000 | 3,064 | 51 | 283 | 0.83 / 1.02 | 0.992 |
| sqlite-vec | 10,000 | 43,334 | 19 | 4 | 2.27 / 2.54 | 1.000 |
| usearch HNSW | 10,000 | 34,105 | 17 | 16 | 0.13 / 0.16 | 0.980 |
| FAISS flat | 10,000 | 162,628 | 15 | 31 | 0.62 / 1.67 | 1.000 |
| Wax | 100,000 | 1,858 | 395 | 482 | 3.86 / 4.44 | 0.998 |
| Chroma HNSW | 100,000 | 2,820 | 408 | 384 | 1.06 / 1.37 | 0.976 |
| sqlite-vec | 100,000 | 40,608 | 192 | 27 | 26.3 / 28.9 | 1.000 |
| usearch HNSW | 100,000 | 12,630 | 169 | 65 | 0.34 / 0.48 | 0.968 |
| FAISS flat | 100,000 | 1,236,051 | 154 | 53 | 1.57 / 2.04 | 1.000 |
| LanceDB IVF-PQ | 100,000 | 22,584 | 177 | 556 | 2.49 / 3.02 | 0.522 |

Wax latency and open figures are the median of three query runs on the final build. Wax
hybrid search (text and vector lanes fused) at 100k: p50 7.8 ms, p95 28.1 ms.

Competitors also ran at 1M: Chroma 4.1 GB at 2.7 ms p50, FAISS flat 1.5 GB at 15.4 ms,
sqlite-vec 1.9 GB at 330 ms. Wax was not run at 1M (see open issues).

## What changed

Fixes on the branch, each with tests:

- **Fusion (`4fc2bd799`).** Hybrid search ranked below either of its own lanes. In order
  of measured effect on LoCoMo R_all@5:
  - The recency lane ranked every recent frame for any "when" question. It now only
    reorders frames that the text or vector lane retrieved, with weight 0.1.
  - Answer-focused reordering and the intent rerank added whole-point bonuses to fused
    scores near 0.1. The answer reorder is now off by default, and intent signals are
    scaled to break near-ties.
  - Text and vector lanes weigh equally (the rule-based classifier used to pick 70/30
    splits), and the RRF constant k is 10 instead of 60.
  - The same answer reorder also cost vector-only search 8 points of recall@10 against
    exact search.
- **Ingest (`7fc4b9505`, `e5be887af`).** Saves commit before the WAL fills, so bulk saves no
  longer fail without `flush()`. Duplicate detection looks up content hashes instead of
  scanning every frame.
- **Store size and open (`52d55b676`, `392245272`, `58d8f761c`, `4ed01f8de`, `2da8d2928`).**
  - Exact-mode search no longer builds a MetalANNS graph on open.
  - Commits reuse space from superseded index segments instead of appending a full copy
    each time.
  - Three crash-recovery paths found in review are covered by tests.
- **Search latency (`7c523d726`, `6c3634747`).** Queries the classifier labels temporal
  ("when", "last", ...) built a recency list over every frame even in vector-only and
  text-only search, which never read it: 95 ms per query at 100k, on 7.4% of queries.
  Single-lane searches skip it, and hybrid selects the newest frames with a bounded heap
  instead of copying and sorting all of them. Vector p95 at 100k: 96.8 ms to 5.7 ms.
- **Open (`c8c97916a`, `d6c933114`, `3006c3a3c`).** Opening a store read and checksummed
  the 153 MB vector segment three times at 100k. It now reads it once. Table-of-contents
  records decode in place instead of copying each field, and the full-text catch-up no
  longer rebuilds the frame list when nothing is pending. Open plus first query at 100k:
  840 ms to 482 ms.
- **Dot-product embedders (`82cd29e13`, `828d03b46`).** `EmbeddingProvider` has a
  `similarity` requirement, default `.cosine`. A store records the similarity of its
  vector index and refuses to open with an embedder that declares another one.
- **Text lane (`52c47c47d`).** Published FTS5 scores went through a curve that mapped
  every real-corpus BM25 value to the same float, so the text-mode rerankers sorted ties
  by snippet heuristics. Scores now keep BM25's order and spacing. Wax text-only search
  now beats normalized BM25 on LoCoMo (R_all@5 0.359 to 0.429, against 0.399) and gains
  on LongMemEval (0.809 to 0.828). Hybrid search ranks by fused rank and is unchanged.
- **Embeddings (`c67cb0088`).** The CoreML autorelease pool drains after every prediction.

## Open issues

1. **LongMemEval multi-session retrieval.** MiniLM trails Contriever by 9 points on
   multi-session questions. The opt-in e5-small-v2 embedder at text weight 0.4 comes
   within 0.002 of Contriever overall (0.900 against 0.902). No small embedder tested
   beats it with Wax's default weights.
2. **Hybrid tail latency.** Hybrid p95 is 28.1 ms at 100k. The full-text query dominates,
   and the structured-memory lane waits behind it on the same database queue even when
   the store has no structured entities.
3. **Per-commit cost grows with store size.** Each commit rewrites the full-text index,
   the vector segment and the table of contents. That limits sustained ingest (1,858
   docs/s at 100k) and is why Wax was not run at 1M. Fixing it needs a file-format change.
4. **Cold open** is 482 ms at 100k, against 384 ms for Chroma. What remains is mostly the
   vector segment's checksum and decode (about 150 ms) and the table-of-contents parse
   (about 105 ms). Going lower needs lazy loading or per-chunk checksums.
