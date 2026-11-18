#!/usr/bin/env bash
# Runs the full Wax speed benchmark matrix: wax-bench perf plus every competitor in
# perf_competitors.py, at each N, writing one JSON file per run and a summary table.
#
# Usage: bash Benchmarks/scripts/perf_run_all.sh
#
# Environment (defaults in brackets):
#   PERF_DIR     work directory holding data/, stores/, results/        [required]
#   PYTHON       interpreter with the competitor packages installed     [$PERF_DIR/venv/bin/python]
#   WAX_BENCH    release wax-bench binary                               [built here into $PERF_DIR/build]
#   DATA         dataset from perf_prepare_data.py                      [$PERF_DIR/data/msmarco-minilm]
#   RESULTS      output directory                                       [$PERF_DIR/results]
#   SIZES        corpus sizes                                           ["10000 100000 1000000"]
#   SYSTEMS      competitor systems                                     [all of them]
#   WAX_SIZES    sizes Wax runs at                                      ["10000 100000"]
#   WAX_FLUSH_EVERY  saves between Memory.flush() calls during Wax ingest   [1000]
#   QUERIES      timed queries per run                                  [1000]
#
# Wax has no public batch save, so its ingest is one Memory.save per passage. Per-save cost
# grows linearly with the store size and every flush rewrites the whole vector index into
# the append-only file, so 1M through the public API would take most of a day and hundreds
# of GB of disk; Wax runs at 10k and 100k by default.
#
# Prepare the dataset once (about 1M MiniLM embeddings; 15-70 min on MPS):
#   "$PYTHON" -I Benchmarks/scripts/perf_prepare_data.py --download-dir "$PERF_DIR/download" \
#       --out "$PERF_DIR/data/msmarco-minilm"
#
# Run it on a quiet machine: plugged in, nothing else heavy running, Low Power Mode off.
set -euo pipefail

: "${PERF_DIR:?set PERF_DIR to the benchmark work directory}"
SCRIPTS="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BENCH_PACKAGE="$(dirname "$SCRIPTS")"
PYTHON="${PYTHON:-$PERF_DIR/venv/bin/python}"
DATA="${DATA:-$PERF_DIR/data/msmarco-minilm}"
RESULTS="${RESULTS:-$PERF_DIR/results}"
STORES="$PERF_DIR/stores"
SIZES="${SIZES:-10000 100000 1000000}"
WAX_SIZES="${WAX_SIZES:-10000 100000}"
WAX_FLUSH_EVERY="${WAX_FLUSH_EVERY:-1000}"
SYSTEMS="${SYSTEMS:-sqlite-vec lancedb-flat lancedb-ivfpq chroma-hnsw faiss-flat faiss-hnsw usearch-hnsw}"
QUERIES="${QUERIES:-1000}"

if [[ -z "${WAX_BENCH:-}" ]]; then
    swift build --package-path "$BENCH_PACKAGE" --build-system native -c release --scratch-path "$PERF_DIR/build"
    WAX_BENCH="$PERF_DIR/build/release/wax-bench"
fi
[[ -f "$DATA/meta.json" ]] || { echo "no dataset at $DATA; run perf_prepare_data.py first" >&2; exit 1; }

mkdir -p "$RESULTS" "$STORES"
{
    echo "{"
    echo "  \"date\": \"$(date -u +%Y-%m-%dT%H:%M:%SZ)\","
    echo "  \"chip\": \"$(sysctl -n machdep.cpu.brand_string)\","
    echo "  \"cores\": $(sysctl -n hw.ncpu),"
    echo "  \"memory_bytes\": $(sysctl -n hw.memsize),"
    echo "  \"macos\": \"$(sw_vers -productVersion)\","
    echo "  \"load_average_at_start\": \"$(sysctl -n vm.loadavg)\","
    echo "  \"wax_commit\": \"$(git -C "$BENCH_PACKAGE/.." rev-parse HEAD)\""
    echo "}"
} > "$RESULTS/machine.json"

for n in $SIZES; do
    if [[ " $WAX_SIZES " == *" $n "* ]]; then
        store="$STORES/wax-$n/store.wax"
        echo "== wax N=$n ingest" >&2
        "$WAX_BENCH" perf --data "$DATA" --n "$n" --store "$store" --phase ingest \
            --flush-every "$WAX_FLUSH_EVERY" --queries "$QUERIES" --out "$RESULTS/wax-$n-ingest.json"
        echo "== wax N=$n query" >&2
        "$WAX_BENCH" perf --data "$DATA" --n "$n" --store "$store" --phase query \
            --queries "$QUERIES" --out "$RESULTS/wax-$n-query.json"
        rm -rf "$STORES/wax-$n"
    fi
    for system in $SYSTEMS; do
        echo "== $system N=$n" >&2
        "$PYTHON" -I "$SCRIPTS/perf_competitors.py" --data "$DATA" --n "$n" --system "$system" \
            --phase all --store-dir "$STORES" --queries "$QUERIES" --out "$RESULTS/$system-$n.json"
        rm -rf "$STORES/$system-$n"
    done
done

"$PYTHON" -I "$SCRIPTS/perf_summarize.py" "$RESULTS" | tee "$RESULTS/summary.md"
