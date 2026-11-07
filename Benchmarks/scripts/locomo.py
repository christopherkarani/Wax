#!/usr/bin/env python3
"""LoCoMo benchmark for Wax: retrieval jobs, evidence recall, reader/judge prompts, scores.

Protocol follows Mem0's published LoCoMo evaluation (mem0ai/mem0 evaluation/,
commit aae5989e, later moved to mem0ai/memory-benchmarks):
- questions in categories 1-4 only (category 5, adversarial, has no gold answer);
- reader prompt: the RAG / full-context prompt from evaluation/src/rag.py, with
  context lines "<session date> | <speaker>: <text>";
- judge: ACCURACY_PROMPT from evaluation/metrics/llm_judge.py (CORRECT / WRONG);
- F1: the set-of-tokens F1 from evaluation/metrics/utils.py.

Category ids as used by Mem0: 1 multi-hop, 2 temporal, 3 open-domain, 4 single-hop.

Steps:
  prepare   --data locomo10.json --jobs jobs.jsonl --gold gold.jsonl
  recall    --gold gold.jsonl --ranked ranked.jsonl          (evidence-turn recall@k)
  reader    --data locomo10.json --gold gold.jsonl --context {retrieval,full}
            [--ranked ranked.jsonl --top-k 30] --out reader.requests.jsonl
  judge     --gold gold.jsonl --hypotheses reader.responses.jsonl --out judge.requests.jsonl
  score     --gold gold.jsonl --hypotheses reader.responses.jsonl --judgements judge.responses.jsonl
"""
import argparse
import json
import re
from collections import defaultdict

CATEGORY_NAMES = {1: "multi-hop", 2: "temporal", 3: "open-domain", 4: "single-hop"}

READER_SYSTEM = (
    "You are a helpful assistant that can answer questions based on the provided context."
    "If the question involves timing, use the conversation date for reference."
    "Provide the shortest possible answer."
    "Use words directly from the conversation when possible."
    "Avoid using subjects in your answer."
)
READER_PROMPT = "\n# Question: \n{question}\n\n# Context: \n{context}\n\n# Short answer:\n"

ACCURACY_PROMPT = """
Your task is to label an answer to a question as ’CORRECT’ or ’WRONG’. You will be given the following data:
    (1) a question (posed by one user to another user),
    (2) a ’gold’ (ground truth) answer,
    (3) a generated answer
which you will score as CORRECT/WRONG.

The point of the question is to ask about something one user should know about the other user based on their prior conversations.
The gold answer will usually be a concise and short answer that includes the referenced topic, for example:
Question: Do you remember what I got the last time I went to Hawaii?
Gold answer: A shell necklace
The generated answer might be much longer, but you should be generous with your grading - as long as it touches on the same topic as the gold answer, it should be counted as CORRECT.

For time related questions, the gold answer will be a specific date, month, year, etc. The generated answer might be much longer or use relative time references (like "last Tuesday" or "next month"), but you should be generous with your grading - as long as it refers to the same date or time period as the gold answer, it should be counted as CORRECT. Even if the format differs (e.g., "May 7th" vs "7 May"), consider it CORRECT if it's the same date.

Now it's time for the real question:
Question: {question}
Gold answer: {gold_answer}
Generated answer: {generated_answer}

First, provide a short (one sentence) explanation of your reasoning, then finish with CORRECT or WRONG.
Do NOT include both CORRECT and WRONG in your response, or it will break the evaluation script.

Just return the label CORRECT or WRONG in a json format with the key as "label".
"""


def load_jsonl(path: str) -> list:
    with open(path) as handle:
        return [json.loads(line) for line in handle]


def conversation_turns(sample: dict) -> list:
    """All turns in order, each with its session date."""
    conversation = sample["conversation"]
    session_numbers = sorted(
        int(key.split("_")[1])
        for key in conversation
        if re.fullmatch(r"session_\d+", key)
    )
    turns = []
    for number in session_numbers:
        date = conversation[f"session_{number}_date_time"]
        for turn in conversation[f"session_{number}"]:
            turns.append({"id": turn["dia_id"], "speaker": turn["speaker"], "text": turn["text"], "date": date})
    return turns


def parse_evidence(evidence: list) -> list:
    """LoCoMo evidence ids are mostly "D<session>:<turn>"; a few entries pack several ids."""
    ids = []
    for entry in evidence:
        ids.extend(re.findall(r"D\d+:\d+", entry))
    return ids


def prepare(args: argparse.Namespace) -> None:
    with open(args.data) as handle:
        samples = json.load(handle)
    with open(args.jobs, "w") as jobs_out, open(args.gold, "w") as gold_out:
        for conv_index, sample in enumerate(samples):
            turns = conversation_turns(sample)
            known = {turn["id"] for turn in turns}
            queries = []
            for q_index, qa in enumerate(sample["qa"]):
                if qa["category"] == 5:
                    continue
                qid = f"conv{conv_index}_q{q_index}"
                queries.append({"qid": qid, "query": qa["question"]})
                gold_out.write(json.dumps({
                    "qid": qid,
                    "conv": conv_index,
                    "category": qa["category"],
                    "question": qa["question"],
                    "answer": str(qa["answer"]),
                    "evidence": [doc for doc in parse_evidence(qa["evidence"]) if doc in known],
                }) + "\n")
            docs = [{"id": turn["id"], "text": f"{turn['speaker']}: {turn['text']}"} for turn in turns]
            jobs_out.write(json.dumps({"queries": queries, "docs": docs}) + "\n")


def recall(args: argparse.Namespace) -> None:
    gold = {entry["qid"]: entry for entry in load_jsonl(args.gold)}
    ranked = {entry["qid"]: entry["ranked"] for entry in load_jsonl(args.ranked)}
    ks = [5, 10, 20, 30, 50]
    totals = defaultdict(float)
    scored = 0
    for qid, entry in gold.items():
        if not entry["evidence"]:
            continue
        scored += 1
        for k in ks:
            top = set(ranked[qid][:k])
            totals[f"recall_all@{k}"] += float(all(doc in top for doc in entry["evidence"]))
            totals[f"recall_any@{k}"] += float(any(doc in top for doc in entry["evidence"]))
    report = {"scored_questions": scored, **{key: value / scored for key, value in totals.items()}}
    print(json.dumps(report, indent=2))
    if args.json_out:
        with open(args.json_out, "w") as handle:
            json.dump(report, handle, indent=2)


def context_lines(turns: list) -> str:
    return "".join(f"{turn['date']} | {turn['speaker']}: {turn['text']}\n" for turn in turns)


def reader(args: argparse.Namespace) -> None:
    with open(args.data) as handle:
        samples = json.load(handle)
    turns_by_conv = [conversation_turns(sample) for sample in samples]
    ranked = {}
    if args.context == "retrieval":
        ranked = {entry["qid"]: entry["ranked"] for entry in load_jsonl(args.ranked)}
    with open(args.out, "w") as out:
        for entry in load_jsonl(args.gold):
            turns = turns_by_conv[entry["conv"]]
            if args.context == "retrieval":
                keep = set(ranked[entry["qid"]][: args.top_k])
                # Chronological order, as the turns appeared in the conversation.
                selected = [turn for turn in turns if turn["id"] in keep]
            else:
                selected = turns
            prompt = READER_PROMPT.format(question=entry["question"], context=context_lines(selected))
            out.write(json.dumps({"id": entry["qid"], "system": READER_SYSTEM, "prompt": prompt}) + "\n")


def judge(args: argparse.Namespace) -> None:
    gold = {entry["qid"]: entry for entry in load_jsonl(args.gold)}
    with open(args.out, "w") as out:
        for hypothesis in load_jsonl(args.hypotheses):
            if hypothesis.get("error"):
                continue
            entry = gold[hypothesis["id"]]
            prompt = ACCURACY_PROMPT.format(
                question=entry["question"], gold_answer=entry["answer"], generated_answer=hypothesis["response"]
            )
            out.write(json.dumps({"id": hypothesis["id"], "prompt": prompt}) + "\n")


def simple_tokenize(text: str) -> list:
    return str(text).lower().replace(".", " ").replace(",", " ").replace("!", " ").replace("?", " ").split()


def token_f1(prediction: str, reference: str) -> float:
    predicted, expected = set(simple_tokenize(prediction)), set(simple_tokenize(reference))
    if not predicted or not expected:
        return 0.0
    common = predicted & expected
    if not common:
        return 0.0
    precision, recall_value = len(common) / len(predicted), len(common) / len(expected)
    return 2 * precision * recall_value / (precision + recall_value)


def judge_label(response: str) -> int:
    match = re.search(r'"label"\s*:\s*"(CORRECT|WRONG)"', response)
    if match:
        return int(match.group(1) == "CORRECT")
    return int("CORRECT" in response and "WRONG" not in response)


def score(args: argparse.Namespace) -> None:
    gold = {entry["qid"]: entry for entry in load_jsonl(args.gold)}
    hypotheses = {entry["id"]: entry for entry in load_jsonl(args.hypotheses) if not entry.get("error")}
    judgements = {entry["id"]: entry for entry in load_jsonl(args.judgements) if not entry.get("error")}
    by_category = defaultdict(lambda: {"j": [], "f1": []})
    for qid, entry in gold.items():
        if qid not in judgements or qid not in hypotheses:
            continue
        bucket = by_category[entry["category"]]
        bucket["j"].append(judge_label(judgements[qid]["response"]))
        bucket["f1"].append(token_f1(hypotheses[qid]["response"], entry["answer"]))
    all_j = [value for bucket in by_category.values() for value in bucket["j"]]
    all_f1 = [value for bucket in by_category.values() for value in bucket["f1"]]
    report = {
        "judged": len(all_j),
        "missing": len(gold) - len(all_j),
        "j": sum(all_j) / len(all_j),
        "f1": sum(all_f1) / len(all_f1),
        "per_category": {
            f"{category} {CATEGORY_NAMES[category]}": {
                "j": sum(bucket["j"]) / len(bucket["j"]),
                "f1": sum(bucket["f1"]) / len(bucket["f1"]),
                "n": len(bucket["j"]),
            }
            for category, bucket in sorted(by_category.items())
        },
    }
    print(json.dumps(report, indent=2))
    if args.json_out:
        with open(args.json_out, "w") as handle:
            json.dump(report, handle, indent=2)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = parser.add_subparsers(dest="command", required=True)
    p = sub.add_parser("prepare")
    p.add_argument("--data", required=True)
    p.add_argument("--jobs", required=True)
    p.add_argument("--gold", required=True)
    p = sub.add_parser("recall")
    p.add_argument("--gold", required=True)
    p.add_argument("--ranked", required=True)
    p.add_argument("--json-out")
    p = sub.add_parser("reader")
    p.add_argument("--data", required=True)
    p.add_argument("--gold", required=True)
    p.add_argument("--context", choices=["retrieval", "full"], required=True)
    p.add_argument("--ranked")
    p.add_argument("--top-k", type=int, default=30)
    p.add_argument("--out", required=True)
    p = sub.add_parser("judge")
    p.add_argument("--gold", required=True)
    p.add_argument("--hypotheses", required=True)
    p.add_argument("--out", required=True)
    p = sub.add_parser("score")
    p.add_argument("--gold", required=True)
    p.add_argument("--hypotheses", required=True)
    p.add_argument("--judgements", required=True)
    p.add_argument("--json-out")
    args = parser.parse_args()
    {"prepare": prepare, "recall": recall, "reader": reader, "judge": judge, "score": score}[args.command](args)


if __name__ == "__main__":
    main()
