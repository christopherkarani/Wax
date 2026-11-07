#!/usr/bin/env python3
"""Score ranked retrieval output against a LongMemEval gold file.

The metric code mirrors LongMemEval src/retrieval/eval_utils.py
(recall_any@k, recall_all@k, ndcg_any@k for k in 1, 3, 5, 10, 30, 50, and the
turn-to-session conversion). Rankings are lists of doc ids, best first; a doc a
retriever did not return is treated as unranked.

Usage:
  longmemeval_score_retrieval.py --gold gold.jsonl --ranked ranked.jsonl [--name wax-hybrid]
"""
import argparse
import json
import math
from collections import defaultdict

KS = [1, 3, 5, 10, 30, 50]


def dcg(relevances, k):
    """Official LongMemEval DCG: relevances[0] + sum(relevances[1:] / log2(arange(2, n + 1))).
    0-based rank i >= 1 is discounted by log2(i + 1), so ranks 0 and 1 both weigh 1. This
    differs from textbook DCG (log2(i + 2)); it is kept so NDCG matches published numbers."""
    relevances = relevances[:k]
    if not relevances:
        return 0.0
    return relevances[0] + sum(rel / math.log2(index + 1) for index, rel in enumerate(relevances[1:], start=1))


def evaluate(ranked, correct, corpus_ids, k):
    """Official evaluate_retrieval over id rankings."""
    top = ranked[:k]
    recalled = set(top)
    recall_any = float(any(doc in recalled for doc in correct))
    recall_all = float(all(doc in recalled for doc in correct))
    correct_set = set(correct)
    ideal = sorted((1 if doc in correct_set else 0 for doc in corpus_ids), reverse=True)
    ideal_dcg = dcg(ideal, k)
    actual = [1 if doc in correct_set else 0 for doc in top]
    ndcg = dcg(actual, k) / ideal_dcg if ideal_dcg else 0.0
    return recall_any, recall_all, ndcg


def strip_turn_id(doc_id):
    return "_".join(doc_id.split("_")[:-1])


def evaluate_turn2session(ranked, correct, corpus_ids, k):
    """Official evaluate_retrieval_turn2session: map turns to sessions, then widen
    the cut until it holds k distinct sessions (or the ranking runs out)."""
    correct_sessions = sorted({strip_turn_id(doc) for doc in correct})
    ranked_sessions = [strip_turn_id(doc) for doc in ranked]
    corpus_sessions = [strip_turn_id(doc) for doc in corpus_ids]
    effective_k = k
    while effective_k <= len(ranked_sessions) and len(set(ranked_sessions[:effective_k])) < k:
        effective_k += 1
    return evaluate(ranked_sessions, correct_sessions, corpus_sessions, effective_k)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--gold", required=True)
    parser.add_argument("--ranked", required=True)
    parser.add_argument("--name", default="run")
    parser.add_argument("--json-out", help="write the metrics JSON here")
    args = parser.parse_args()

    gold = {}
    with open(args.gold) as handle:
        for line in handle:
            entry = json.loads(line)
            gold[entry["qid"]] = entry
    ranked = {}
    latency = []
    with open(args.ranked) as handle:
        for line in handle:
            entry = json.loads(line)
            ranked[entry["qid"]] = entry["ranked"]
            if "search_ms" in entry:
                latency.append(entry["search_ms"])

    missing = [qid for qid, entry in gold.items() if entry["skip"] is None and qid not in ranked]
    if missing:
        raise SystemExit(f"{len(missing)} scored questions have no ranking, e.g. {missing[:3]}")

    granularity = next(iter(gold.values()))["granularity"]
    levels = ["session"] if granularity == "session" else ["turn", "session"]
    totals = {level: defaultdict(float) for level in levels}
    by_type = defaultdict(lambda: defaultdict(float))
    type_counts = defaultdict(int)
    scored = 0
    for qid, entry in gold.items():
        if entry["skip"] is not None:
            continue
        scored += 1
        type_counts[entry["question_type"]] += 1
        for k in KS:
            if granularity == "session":
                results = {"session": evaluate(ranked[qid], entry["correct"], entry["corpus_ids"], k)}
            else:
                results = {
                    "turn": evaluate(ranked[qid], entry["correct"], entry["corpus_ids"], k),
                    "session": evaluate_turn2session(ranked[qid], entry["correct"], entry["corpus_ids"], k),
                }
            for level, (r_any, r_all, ndcg) in results.items():
                totals[level][f"recall_any@{k}"] += r_any
                totals[level][f"recall_all@{k}"] += r_all
                totals[level][f"ndcg_any@{k}"] += ndcg
            if k in (5, 10):
                r_any, r_all, ndcg = results["session"]
                by_type[entry["question_type"]][f"session_recall_all@{k}"] += r_all
                by_type[entry["question_type"]][f"session_ndcg_any@{k}"] += ndcg

    metrics = {level: {key: value / scored for key, value in values.items()} for level, values in totals.items()}
    per_type = {
        qtype: {key: value / type_counts[qtype] for key, value in values.items()}
        for qtype, values in by_type.items()
    }
    latency.sort()
    report = {
        "name": args.name,
        "granularity": granularity,
        "scored_questions": scored,
        "skipped": sum(1 for entry in gold.values() if entry["skip"] is not None),
        "metrics": metrics,
        "per_type": per_type,
    }
    if latency:
        report["search_ms"] = {
            "p50": latency[len(latency) // 2],
            "p95": latency[min(len(latency) - 1, int(len(latency) * 0.95))],
        }
    if args.json_out:
        with open(args.json_out, "w") as handle:
            json.dump(report, handle, indent=2)
    summary = metrics["session"]
    print(
        f"{args.name} [{granularity}] n={scored} session: "
        f"R_all@5={summary['recall_all@5']:.3f} R_all@10={summary['recall_all@10']:.3f} "
        f"R_any@5={summary['recall_any@5']:.3f} NDCG@10={summary['ndcg_any@10']:.3f}"
    )


if __name__ == "__main__":
    main()
