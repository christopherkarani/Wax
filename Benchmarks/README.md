# Wax memory benchmarks

Reproducible retrieval, end-to-end QA, and systems benchmarks for Wax. Results and
analysis: [Resources/docs/benchmarks/2026-11-06-memory-benchmarks.md](../Resources/docs/benchmarks/2026-11-06-memory-benchmarks.md).

This is a separate SwiftPM package so the benchmark harness never ships with Wax. It
depends on the parent package with the `MiniLMEmbeddings`, `ArcticEmbeddings` and `E5Embeddings` traits.

| Benchmark | What it measures | Protocol source |
|---|---|---|
| LongMemEval-S retrieval | Does Wax find the evidence sessions/turns? | LongMemEval `src/retrieval` (commit 9e0b455f) |
| LongMemEval-S QA | Answer accuracy with Wax as the memory | LongMemEval `src/generation`, `src/evaluation` |
| LoCoMo retrieval + QA | Evidence recall and LLM-judge accuracy (J) | Mem0 `evaluation/` (commit aae5989e) |
| Systems | Ingest rate, disk, cold open, query latency, recall@10 vs exact | MS MARCO passages + all-MiniLM-L6-v2 |

## Layout

```
Sources/WaxBench/main.swift       wax-bench retrieve: fresh store per job, public Memory API only
Sources/WaxBench/Perf.swift       wax-bench perf: ingest / query timing on precomputed vectors
Sources/WaxBench/HTTPEmbeddings.swift  --embedder http://...: embed through scripts/embed_server.py
scripts/longmemeval_prepare.py    LongMemEval JSON -> jobs + gold (official corpus and filter logic)
scripts/longmemeval_score_retrieval.py  official recall_any/recall_all/ndcg_any, turn->session
scripts/longmemeval_baselines.py  bm25 / bm25norm / minilm / contriever / stella reference retrievers
scripts/longmemeval_qa.py         reader prompts (CoT, json history), per-type judge prompts, scoring
scripts/locomo.py                 LoCoMo prepare / recall / reader / judge / score (Mem0 prompts)
scripts/llm_run.py                resumable parallel runner over `claude -p`
scripts/embed_server.py           local HTTP embedder, so Wax and a baseline can share one model
scripts/perf_*.py, perf_run_all.sh  systems benchmark data prep, competitors, driver, summary
```

## Build

```bash
cd Benchmarks
swift build -c release --build-system native   # native: the swiftbuild backend fails on Swift 6.4 here
```

Building a sub-package with traits can rewrite the parent `Package.resolved`; restore it
with `git checkout -- ../Package.resolved` afterwards.

## Data

Downloaded data is untrusted: keep it in its own directory and run Python with `-I`.

```bash
DATA=/path/to/bench-data; mkdir -p $DATA/longmemeval $DATA/locomo
for f in longmemeval_s_cleaned.json longmemeval_oracle.json; do
  curl -L -o $DATA/longmemeval/$f https://huggingface.co/datasets/xiaowu0162/longmemeval-cleaned/resolve/main/$f
done
curl -L -o $DATA/locomo/locomo10.json https://raw.githubusercontent.com/snap-research/locomo/main/data/locomo10.json
```

## 1. LongMemEval-S retrieval

```bash
RUNS=/path/to/runs; S=Benchmarks/scripts; BIN=Benchmarks/.build/release/wax-bench
for g in session turn; do
  python3 -I $S/longmemeval_prepare.py --input $DATA/longmemeval/longmemeval_s_cleaned.json \
    --granularity $g --jobs $RUNS/lme_s_$g.jobs.jsonl --gold $RUNS/lme_s_$g.gold.jsonl
done
# Wax: --mode text | vector | hybrid | hybrid:<alpha>, --embedder minilm | arctic | e5
$BIN retrieve --input $RUNS/lme_s_session.jobs.jsonl --output $RUNS/wax-vector-minilm-session.ranked.jsonl \
  --mode vector --embedder minilm --top-k 300 --concurrency 4
python3 -I $S/longmemeval_score_retrieval.py --gold $RUNS/lme_s_session.gold.jsonl \
  --ranked $RUNS/wax-vector-minilm-session.ranked.jsonl --name wax-vector --json-out $RUNS/wax-vector.metrics.json
# Reference retrievers (needs torch, transformers, sentence-transformers, rank_bm25)
python3 -I $S/longmemeval_baselines.py --jobs $RUNS/lme_s_session.jobs.jsonl --retriever contriever \
  --cache-dir $RUNS/vec-cache --out $RUNS/baseline-contriever-session.ranked.jsonl
```

To compare the Wax pipeline with a bare retriever on the same model, serve that model
locally and point Wax at it. Vectors come from `scripts/embed_server.py` (mean pooling, as
in the baselines); Wax still does the chunking, text lane and fusion.

```bash
python3 -I $S/embed_server.py --model facebook/contriever --port 8765 &   # torch + transformers
$BIN retrieve --input $RUNS/lme_s_session.jobs.jsonl --output $RUNS/wax-hybrid-contriever.ranked.jsonl \
  --mode hybrid --embedder http://127.0.0.1:8765 --embedder-similarity dot --top-k 300 --concurrency 4
```

Contriever was trained for dot product, so pass `--embedder-similarity dot` (default
`cosine`): Wax then keeps the server's unnormalized vectors and ranks by inner product, as
the bare baseline does. It applies to `--embedder http://...` only.

`--top-k 300` is deliberate: Wax returns chunks, and several chunks of one session collapse
to one doc id, so a small top-k yields fewer than 50 distinct sessions. 419 of 500 questions
are scored (30 abstention questions and 51 without user-side evidence are skipped, as in
the official code).

## 2. LongMemEval-S QA

Reader `claude-haiku-5-5`, judge `claude-sonnet-5-5`, both through `claude -p` with no tools,
settings, MCP servers, or slash commands. Numbers are comparable to the other rows of this
report, not to papers that used GPT-4o.

```bash
python3 -I $S/longmemeval_qa.py reader --data $DATA/longmemeval/longmemeval_s_cleaned.json \
  --context retrieval --ranked $RUNS/wax-vector-minilm-session.ranked.jsonl --top-k 5 --out reader.jsonl
#   --context oracle --oracle-data $DATA/longmemeval/longmemeval_oracle.json   (evidence sessions only)
python3 -I $S/llm_run.py --input reader.jsonl --output reader.responses.jsonl --model claude-haiku-5-5
python3 -I $S/longmemeval_qa.py judge --data ... --hypotheses reader.responses.jsonl --out judge.jsonl
python3 -I $S/llm_run.py --input judge.jsonl --output judge.responses.jsonl --model claude-sonnet-5-5
python3 -I $S/longmemeval_qa.py score --data ... --judgements judge.responses.jsonl --json-out qa.metrics.json
```

`llm_run.py` is resumable: re-run the same command to retry failed requests.

## 3. LoCoMo

```bash
python3 -I $S/locomo.py prepare --data $DATA/locomo/locomo10.json --jobs $RUNS/locomo.jobs.jsonl --gold $RUNS/locomo.gold.jsonl
$BIN retrieve --input $RUNS/locomo.jobs.jsonl --output $RUNS/locomo-wax-vector.ranked.jsonl --mode vector --top-k 100
python3 -I $S/locomo.py recall --gold $RUNS/locomo.gold.jsonl --ranked $RUNS/locomo-wax-vector.ranked.jsonl
python3 -I $S/locomo.py reader --data $DATA/locomo/locomo10.json --gold $RUNS/locomo.gold.jsonl \
  --context retrieval --ranked $RUNS/locomo-wax-vector.ranked.jsonl --top-k 30 --out reader.jsonl   # or --context full
# then llm_run.py (haiku), locomo.py judge, llm_run.py (sonnet), locomo.py score
```

Categories 1-4 only (1,540 questions); category 5 has no gold answer.

## 4. Systems benchmark

```bash
export PERF_DIR=/path/to/perf   # needs a venv at $PERF_DIR/venv with the competitor packages, or set PYTHON
$PERF_DIR/venv/bin/python -I $S/perf_prepare_data.py --download-dir $PERF_DIR/download \
  --out $PERF_DIR/data/msmarco-minilm                                       # 1M passages, ~70 min on MPS
bash $S/perf_run_all.sh                                                     # 1-1.5 h on a quiet M3 Max
```

Run it on an idle machine; `machine.json` records the load average at start. Wax runs at
10k and 100k only: every commit still rewrites the full-text and vector indexes, so ingest
through the public `Memory` API slows as the store grows and 1M is not practical (see the report).
