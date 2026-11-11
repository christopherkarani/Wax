# Wax memory benchmarks, November 2026

Retrieval, end-to-end QA, and systems results for Wax on branch
`feat/metalanns-0.4-benchmarks` (MetalANNS 0.4.0). Every number here comes from the
harness in [`Benchmarks/`](../../../Benchmarks/README.md), which documents how to reproduce it.

## Summary

| Benchmark | Metric | Wax | Best reference | Before fixes |
|---|---|---|---|---|
| LoCoMo retrieval | R_all@5 / @10 | **0.609 / 0.686** (hybrid, e5-small-v2, text weight 0.4, MiniLM reranker); 0.555 / 0.636 without the reranker | Contriever 0.407 / 0.494 | 0.186 / 0.294 |
| LoCoMo QA | LLM judge J | **73.8%** (hybrid, e5-small-v2, text weight 0.4, MiniLM reranker, top 30); 72.0% without the reranker; 64.9% with MiniLM | Contriever top 30: 62.4%; memvid top 30: 57.0% | 56.3% (vector, top 30) |
| LongMemEval-S retrieval | R_all@5 / NDCG@10 | **0.938 / 0.950** (hybrid, e5-small-v2, text weight 0.4, MiniLM reranker); 0.905 / 0.926 without the reranker | Contriever 0.902 / 0.927 | 0.742 / – |
| LongMemEval-S QA | accuracy, mean of 3 runs | **89.4%** (hybrid, e5-small-v2, text weight 0.4, MiniLM reranker, top 5); task-averaged 90.2% | Contriever top 5: 87.7%; task-averaged 90.0% | 83.0% (vector, top 5) |
| Systems, 100k passages | vector recall@10 | **0.998** | Chroma HNSW 0.976 | 0.902 |
| Systems, 100k passages | ingest | 13,826 docs/s with `importDocuments`; 9,674 saving one at a time | sqlite-vec 43,584; FAISS flat 484k (vectors only); Chroma 2,541 | 136 docs/s |
| Systems, 100k passages | disk | 308 MB with `importDocuments`; 417 MB saving one at a time | Chroma 408 MB (text + vectors) | 13.5 GB |
| Systems, 100k passages | vector p50 / p95 | **1.09** / 1.57 ms | Chroma HNSW 1.13 / 1.41 ms; FAISS flat 1.40 / 1.46 ms | 64–97 ms (p95) |
| Systems, 100k passages | cold open + first query | **406 ms** | Chroma HNSW 511 ms | 840 ms |

Wax leads every retrieval and QA benchmark here. With the e5-small-v2 embedder (the default for new stores)
(33M parameters, against Contriever's 110M) and the opt-in MiniLM cross-encoder reranker
(22 MB, on device), LongMemEval-S retrieval reaches 0.938 R_all@5 against Contriever's 0.902,
and QA accuracy 89.4% against 87.7% over three reader and judge runs each (the lowest
reranked run, 89.0%, beats Contriever's highest, 87.8%). Task-averaged QA is a tie (90.2%
against 90.0%). Without the reranker, LongMemEval ties Contriever (0.905 retrieval, 87.6%
QA). With the default MiniLM-L6 embedder and no reranker it is 1.9 points behind in
retrieval and 1.8 points behind in QA. With Contriever embeddings Wax ties bare Contriever
on LongMemEval and adds 8 points on LoCoMo (see [Same-model comparison](#same-model-comparison)).
On LoCoMo QA, Wax with e5 and the reranker reaches 73.8% against full context's 76.6%, and
memvid, given the same MiniLM vectors as Wax's 64.9% row, scores 57.0% (see [memvid](#memvid)).

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
| Wax hybrid, e5-small-v2, text weight 0.4, MiniLM reranker (top 20, RRF k=10) | **0.938** | **0.981** | **0.950** |
| Wax hybrid, e5-small-v2, text weight 0.4 | 0.905 | 0.976 | 0.926 |
| Contriever | 0.902 | 0.971 | 0.927 |
| Wax hybrid, e5-small-v2 | 0.893 | 0.969 | 0.925 |
| Wax vector, e5-small-v2 | 0.885 | 0.952 | 0.893 |
| Wax hybrid, e5-small-v2 without prefixes, text weight 0.4 | 0.900 | 0.967 | 0.927 |
| Wax hybrid, e5-small-v2 without prefixes | 0.885 | 0.957 | 0.924 |
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
lowered to 0.4 (`.hybrid(alpha: 0.4)`) reached 0.900, against Contriever's 0.902. It ships
as the `E5Embeddings` trait (`7b1892861`). Since FP16 compute made it cheaper to embed than MiniLM, it is on by default, and `.automatic` gives new stores e5 while stores bound to MiniLM keep MiniLM.

e5 was trained with `"query: "` before queries and `"passage: "` before passages, and the
first build embedded both bare. With the prefixes (`802f8ffa8`), hybrid at text weight 0.4
goes from 0.900 to 0.905 on LongMemEval and from 0.503 to 0.555 on LoCoMo. Vector-only
search drops slightly on LongMemEval (0.893 to 0.885) and rises on LoCoMo (0.448 to
0.528). The e5 rows come from the bundled Core ML model, whose embeddings match PyTorch to
a cosine of at least 0.9996 on 215 texts.

The bundled model computes in FP16 over INT8 weights. Against the earlier FP32 graph, in
paired runs on the CPU, FP16 halves embedding cost and leaves retrieval unchanged:
LongMemEval took 471 CPU s against 988 (MiniLM: 554), with R_all@5 0.905 and R_all@10 0.976
both. LoCoMo took 28.7 CPU s against 61 (MiniLM: 34.5), with R_all@5 0.5544 against 0.5550
(one question). Embeddings match PyTorch to a cosine of at least 0.99980 on the reference
texts, up to 512 tokens.

A rule that picked the text weight from the corpus's median document length scored
0.912 on LongMemEval but failed a held-out check (LongMemEval turn level), so it was not
shipped.

### Reranking

`Memory.Config.reranking = .builtIn(.msMarcoMiniLM)` (opt-in, off by default) rescores the
top candidates with cross-encoder/ms-marco-MiniLM-L-6-v2, bundled as a 22 MB Core ML model
behind the `MiniLMReranker` trait. Each frame is scored as its best 288-token window, and
the reranker order is fused with the retrieval order by reciprocal rank (k = 10). The
graph computes in FP16 over INT8 weights; scores match PyTorch to 0.084 logits on the CPU
and 0.020 on the GPU over the reference pairs.

The runs are paired: the reranked run's pre-rerank order matched the base run on all 500
LongMemEval queries. On LongMemEval, reranking the top 20 takes R_all@5 from 0.905 to
0.938 (17 questions gained, 3 lost; sign test p = 0.003). On LoCoMo, reranking the top 50
takes it from 0.555 to 0.609 (102 gained, 19 lost). Reproduce with `wax-bench retrieve ...
--rerank minilm --rerank-candidates 20 --rerank-fusion rrf:10`.

Search with reranking, p50 and p95 per query on the CPU (M3 Max, `--rerank-compute cpu`,
prediction batch 8, four jobs at once, back-to-back runs on a loaded machine):

| | LongMemEval (top 20) | LoCoMo (top 50) |
|---|---|---|
| FP32 graph (before) | 374 / 600 ms, R_all@5 0.938 | 338 / 382 ms, R_all@5 0.6091 |
| FP16 graph (shipped) | 232 / 331 ms, R_all@5 0.938 | 180 / 208 ms, R_all@5 0.6085 |

FP16 compute also cut CPU time per LoCoMo run from 274 to 155 s. The Neural Engine does not
help: the FP32 graph cannot run there, so `--rerank-compute ane` fell back to the CPU, and an
FP16 graph with fixed shapes ran on it at 1.8 s p50. Fixed shapes alone made the CPU
slower (395 ms p50 on LoCoMo).

## LoCoMo retrieval

Mem0's evaluation protocol (commit aae5989e), categories 1–4: 1,540 questions, of which
the 1,535 with evidence turns are scored. R_all@k: every evidence turn is in the top k.

| Retriever | R_all@5 | R_all@10 | R_all@30 |
|---|---|---|---|
| Wax hybrid, e5-small-v2, text weight 0.4, MiniLM reranker (top 50, RRF k=10) | **0.609** | **0.686** | **0.767** |
| Wax hybrid, e5-small-v2, text weight 0.4 | 0.555 | 0.636 | 0.744 |
| Wax hybrid, e5-small-v2 | 0.545 | 0.623 | 0.734 |
| Wax hybrid, Arctic | 0.537 | 0.618 | 0.725 |
| Wax vector, e5-small-v2 | 0.528 | 0.612 | 0.726 |
| Wax vector, Arctic | 0.509 | 0.586 | 0.717 |
| Wax hybrid, e5-small-v2 without prefixes | 0.509 | 0.579 | 0.687 |
| Wax hybrid, e5-small-v2 without prefixes, text weight 0.4 | 0.503 | 0.583 | 0.690 |
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
| Wax hybrid e5-small-v2, text weight 0.4, MiniLM reranker (top 20, RRF k=10), top 5, mean of 3 runs (90.0 / 89.0 / 89.2) | **89.4%** | 90.2% |
| Contriever top 5, mean of 3 runs (87.8 / 87.6 / 87.6) | 87.7% | 90.0% |
| Wax hybrid e5-small-v2, text weight 0.4, top 5, mean of 3 runs (87.6 / 87.4 / 87.8) | 87.6% | **90.3%** |
| Wax hybrid MiniLM top 5 | 86.0% | 88.2% |
| Wax vector MiniLM top 5, before fixes | 83.0% | 84.8% |

Three runs each are needed to compare these: the reader and judge alone move accuracy by
0.4 points between runs of the same context. With the reranker, the lowest of the three runs
(89.0%) is 1.2 points above Contriever's highest (87.8%). The gain is mostly multi-session
questions (82.1% against Contriever's 78.5% and 76.6% without the reranker); temporal
reasoning is 86.9%, knowledge-update 96.3% and single-session user facts 99.0%.
Task-averaged accuracy does not move (90.2% against 90.3% without it), because single-session
preference (81.1%) and abstention (88.9%), 30 questions each, weigh as much as the larger
types. With e5, Wax leads Contriever on
knowledge-update (96.8% against 90.3%) and single-session user facts (98.4% against
95.3%), and trails on multi-session (76.6% against 78.5%), single-session preference and
abstention (both 3.3 points). The abstention gap is not retrieval: on the questions that
flipped, both contexts held the right sessions and the answers differed in wording, and
the oracle context scores 73.3% on abstention. On multi-session questions Wax has every
evidence session in its top 5 more often than Contriever (86.8% against 85.1%).

With MiniLM, Wax hybrid beats Contriever on knowledge-update (95.8% against 90.3%) and abstention
(90.0% against 83.3%), ties on single-session user facts (95.3%), and is within 3.3 points
on the other single-session and temporal types. It trails on multi-session (69.4%
against 78.5%), which follows the retrieval gap above.

### LoCoMo (1,540 questions)

| Context | J | F1 | Multi-hop | Temporal | Open-domain | Single-hop |
|---|---|---|---|---|---|---|
| Full conversation | **76.6%** | 0.461 | **67.4%** | 70.1% | 52.1% | **85.0%** |
| Wax hybrid e5-small-v2, text weight 0.4, MiniLM reranker (top 50, RRF k=10), top 30 | 73.8% | **0.482** | 58.9% | **71.7%** | **54.2%** | 81.8% |
| Wax hybrid e5-small-v2, text weight 0.4, top 30 | 72.0% | **0.482** | 57.8% | 67.3% | 47.9% | 81.3% |
| Wax hybrid Arctic top 30 | 70.4% | 0.471 | 55.7% | 61.1% | 51.0% | 81.1% |
| Wax hybrid MiniLM top 30 | 64.9% | 0.445 | 43.6% | 58.3% | 46.9% | 76.7% |
| Contriever top 30 | 62.4% | 0.435 | 48.6% | 52.6% | 49.0% | 72.3% |
| memvid vector (MiniLM vectors) top 30 | 57.0% | 0.392 | 42.2% | 53.9% | 44.8% | 64.6% |
| memvid hybrid, OR-joined query (MiniLM vectors) top 30 | 51.6% | 0.353 | 37.6% | 50.5% | 40.6% | 57.9% |
| Wax vector MiniLM top 30, before fixes | 56.3% | 0.383 | 39.0% | 51.1% | 44.8% | 65.4% |

Each LoCoMo row is one reader and judge run. The e5 runs are paired (same retrieval before
reranking): the reranker gained 112 questions and lost 85 (sign test p = 0.06), so its 1.8
points are suggestive, not established. Reranked, temporal questions score above full context
(71.7% against 70.1%), as do token F1 (0.482 against 0.461) and open-domain (54.2% against
52.1%).

## Systems

MS MARCO passages with precomputed all-MiniLM-L6-v2 vectors, 1,000 queries,
recall@10 against exact search. Wax ingests through `Memory.save` with no manual flush,
and in a second row through the atomic bulk load `Memory.importDocuments`; the competitors
bulk-load. Wax's disk figure includes the text, the full-text index and
metadata; most competitors store vectors only.

| System | N | Ingest docs/s | Disk MB | Cold open + 1st query ms | Vector p50 / p95 ms | Recall@10 |
|---|---|---|---|---|---|---|
| Wax | 10,000 | 3,401 | 53 | 81 | 2.23 / 2.81 | 0.998 |
| Chroma HNSW | 10,000 | 3,064 | 51 | 283 | 0.83 / 1.02 | 0.992 |
| sqlite-vec | 10,000 | 43,334 | 19 | 4 | 2.27 / 2.54 | 1.000 |
| usearch HNSW | 10,000 | 34,105 | 17 | 16 | 0.13 / 0.16 | 0.980 |
| FAISS flat | 10,000 | 162,628 | 15 | 31 | 0.62 / 1.67 | 1.000 |
| Wax `save` | 100,000 | 9,674 | 417 | 406 | 1.09 / 1.57 | 0.998 |
| Wax `importDocuments` | 100,000 | 13,826 | 308 | – | – | 0.998 |
| Chroma HNSW | 100,000 | 2,541 | 408 | 511 | 1.13 / 1.41 | 0.976 |
| sqlite-vec | 100,000 | 43,584 | 192 | 27 | 24.8 / 26.2 | 1.000 |
| usearch HNSW | 100,000 | 16,738 | 168 | 62 | 0.27 / 0.34 | 0.966 |
| FAISS flat | 100,000 | 484,381 | 154 | 50 | 1.40 / 1.46 | 1.000 |
| LanceDB IVF-PQ | 100,000 | 22,584 | 177 | 556 | 2.49 / 3.02 | 0.522 |

The 100k rows for Wax `save`, Chroma, sqlite-vec, usearch and FAISS flat were rerun
together on 2026-11-11 at `7f857833c`, load average 5–12: Wax figures are medians of three
fresh ingest-and-query passes, competitor figures are single runs. The `importDocuments`,
LanceDB and 10k rows are from the earlier runs at load average 30–125. Wax hybrid search
(text and vector lanes fused) at 100k: p50 4.6 ms, p95 14.8 ms, p99 18.9 ms (before
`386a642e1`: 7.7 / 27.6 / 37.2 ms, interleaved runs, load average 5.9).

Competitors also ran at 1M: Chroma 4.1 GB at 2.7 ms p50, FAISS flat 1.5 GB at 15.4 ms,
sqlite-vec 1.9 GB at 330 ms. Wax was not run at 1M (see open issues).

## memvid

memvid (`memvid-sdk` 2.0.160, the Rust rewrite; the QR-video v1 is deprecated) is a
single-file memory store with BM25 (Tantivy), HNSW vectors and a hybrid mode. Its local
embedder is not built for macOS arm64, so every run below gives it the same precomputed
all-MiniLM-L6-v2 vectors as the Wax MiniLM and bare MiniLM rows, through the same jobs
files and scorers. Adapters: `Benchmarks/scripts/retrieve_memvid.py` and
`perf_memvid.py`, which set `MEMVID_TELEMETRY=0`.

| Benchmark | memvid, best mode | Wax hybrid, MiniLM | Bare MiniLM |
|---|---|---|---|
| LongMemEval-S R_all@5 / @10 / NDCG@10 | 0.809 / 0.885 / 0.838 (vector) | **0.883 / 0.950 / 0.917** | 0.852 / 0.938 / 0.878 |
| LoCoMo R_all@5 / @10 | 0.332 / 0.405 | **0.466 / 0.550** | 0.326 / 0.406 |

memvid's hybrid mode adds nothing over its vector mode with raw queries (LongMemEval
0.742, LoCoMo 0.325): multi-word lexical queries behave as AND in 2.0.160, though the
docs say OR, so most match nothing. The LoCoMo row is its better result with the query
rewritten as OR terms at @5 and vector search at @10. On LongMemEval 24 questions have a
gold session memvid never returns.

The cause is a memvid bug that also blocks a systems row. Vectors written in a large
`put_many` call are stored but cannot be found: of a 1,000-document batch, 495 never come
back for their own vector, so 10k passages loaded in one call score recall@10 0.003. With
10-document batches nothing is lost, which is how the retrieval runs above were loaded,
but the 10k passages then exceed the free tier's 50 MB file cap. 1,000-document batches
deadlocked on the second or third call. At 100k the cap rules it out. For reference, the
one-call 10k load ran at 8.6 docs/s and 46.6 MB, with 100 ms cold open and first query.

LoCoMo QA through the same reader, judge and top 30 as every other row: memvid vector
57.0% and hybrid-or 51.6%, against 64.9% for Wax hybrid on the same MiniLM vectors and 62.4%
for Contriever (per-category figures in the [LoCoMo QA table](#locomo-1540-questions)).
hybrid-or loses to vector because its R_all@30 is 0.450 against 0.548, and the reader sees
the top 30. Rerun on 2026-11-10 with the same versions, its recall reproduced the figures
above exactly (bare MiniLM 0.326 / 0.406 from the same vectors).

memvid publishes LoCoMo 85.65% (categories 1–4, 1,540 questions). That run uses GPT-4o
as reader, gpt-4o-mini as a lenient judge, OpenAI text-embedding-3-large embeddings and
60 retrieved items. Our runs use claude-haiku-5-5 as reader, claude-sonnet-5-5 as judge,
on-device embedders and 30 items, so the figures cannot be compared. memvid publishes no
retrieval recall and no LongMemEval results.

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
- **Full-text fan-out (`386a642e1`, `c890c4b6d`).** 96% of 100k queries match no row
  with AND, so the OR fallback runs, and SQLite scores and snippets every matching row
  (about a third of the corpus) before `LIMIT`. Indexes with 50k or more documents now
  split that query across up to four read-only connections by rowid range and merge the
  results. `bm25()` takes its statistics from the whole table, so the rows, ranks and
  snippets are identical to a single query (checked on all 3,922 query plans of the 100k
  index). Hybrid p95 at 100k: 27.6 ms to 14.8 ms; recall unchanged.
- **Index writes (`487c5c53d`).** A flush cleared text-index ops queued while its write
  was in flight, so those frames never reached the text index. Flushes now settle only
  the ops they wrote.
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
- **Text-index commits (`0aefdef06`, `c7a815632`, `8df2de8b3`, `4e3b4bff6`).** A commit
  rewrote, hashed and wrote the whole FTS5 database, about 40% of commit work at 100k. It
  now writes only the pages that changed, as a delta run against a base image, and writes a
  new base once the deltas pass a quarter of the image or 32 runs. File format 3.0; older
  stores are adopted on their first commit. Saving one at a time at 100k: 92 to 88 billion
  instructions, store 495 to 417 MB.
- **Bulk import (`9ed294808`, `d30a432d4`, `60b30f8bc`, `aba291023`).** New
  `Memory.importDocuments(_:)` writes payloads outside the WAL, builds the text and vector
  additions once and commits once; nothing is visible until it returns, and a failure or
  crash leaves the store as it was. At 100k: 46 billion instructions, 7.2 CPU s, 13,826
  docs/s and 308 MB, against 61 billion, 10.0 s, 7,713 docs/s and 495 MB for
  `save(contentsOf:)` in batches of 1,024. Results match `save(contentsOf:)` in every
  search mode.
- **Vector search overhead (`b2aab5121`, `402293c54`).** Every search ran the
  structured-memory lane's alias lookups (about seven SQLite queries) even in a store with
  no entities, and packing the context encoded each snippet twice. Vector p50 at 100k
  halved in back-to-back runs on a heavily loaded machine (8.0 to 4.0 ms). MetalANNS graph
  search was measured and left off: its best setting reached recall@10 0.979 (HNSW, ef 512)
  and adds about 15 s to opening a 100k store.

## Open issues

1. **LongMemEval multi-session retrieval.** MiniLM trails Contriever by 9 points on
   multi-session questions. The e5-small-v2 embedder (default for new stores) at text weight 0.4 comes
   within 0.002 of Contriever overall (0.900 against 0.902). No small embedder tested
   beats it with Wax's default weights.
2. **Hybrid tail latency.** Hybrid p95 is 14.8 ms at 100k, against 1.6 ms for vector
   search. The OR fallback still scores every matching row. Going under 10 ms needs top-k
   pruning (MaxScore or WAND), which stock FTS5 cannot do: a custom `bm25` function or a
   separate inverted index.
3. **Ingest against bulk-loading stores.** Commits now write text-index and vector deltas,
   but still rewrite and hash the whole table of contents (about 15% of commit work at
   100k). Wax ingests 9,674 docs/s saving one at a time and 13,826 with `importDocuments`,
   against 17k–484k for the vector-only stores. Wax was not run at 1M.
4. **Cold open** is 406 ms at 100k, ahead of Chroma's 511 ms but far behind the
   vector-only stores (27–62 ms). What remains is mostly the vector segment's checksum and
   decode and the table-of-contents parse. Going lower needs lazy loading or per-chunk
   checksums.
