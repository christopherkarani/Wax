#!/usr/bin/env python3
"""Turn a LongMemEval file into wax-bench retrieval jobs plus a gold file.

Corpus construction follows the official retriever
(LongMemEval src/retrieval/run_retrieval.py, process_item_flat_index):

- session granularity: one doc per session, the user turns joined with spaces.
  An evidence session whose user turns carry no `has_answer` label is renamed
  `noans_*`, so it does not count as a hit.
- turn granularity: one doc per user turn, id `<session_id>_<turn_number>`.
  Turns in evidence sessions without `has_answer` are renamed `noans_*`.

A doc is correct when its id contains "answer". Abstention questions (`_abs`)
and questions with no labelled user evidence turn are marked `skip` and left
out of retrieval metrics, as in the official script.
"""
import argparse
import json


def session_docs(session, session_id):
    user_turns = [turn for turn in session if turn["role"] == "user"]
    text = " ".join(turn["content"] for turn in user_turns)
    doc_id = session_id
    if "answer" in session_id and not any(turn.get("has_answer") for turn in user_turns):
        doc_id = session_id.replace("answer", "noans")
    return [{"id": doc_id, "text": text}]


def turn_docs(session, session_id):
    docs = []
    for index, turn in enumerate(session):
        if turn["role"] != "user":
            continue
        doc_id = f"{session_id}_{index + 1}"
        if "answer" in session_id and not turn.get("has_answer"):
            doc_id = doc_id.replace("answer", "noans")
        docs.append({"id": doc_id, "text": turn["content"]})
    return docs


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--input", required=True, help="longmemeval_s_cleaned.json or similar")
    parser.add_argument("--granularity", choices=["session", "turn"], required=True)
    parser.add_argument("--jobs", required=True, help="output jobs JSONL for wax-bench")
    parser.add_argument("--gold", required=True, help="output gold JSONL for the scorer")
    parser.add_argument("--limit", type=int, default=0, help="first N questions only (0 = all)")
    args = parser.parse_args()

    with open(args.input) as handle:
        questions = json.load(handle)
    if args.limit:
        questions = questions[: args.limit]

    build = session_docs if args.granularity == "session" else turn_docs
    with open(args.jobs, "w") as jobs_out, open(args.gold, "w") as gold_out:
        for question in questions:
            docs = []
            for session, session_id in zip(question["haystack_sessions"], question["haystack_session_ids"]):
                docs.extend(build(session, session_id))
            has_target = any(
                turn.get("has_answer")
                for session in question["haystack_sessions"]
                for turn in session
                if turn["role"] == "user"
            )
            skip = None
            if "_abs" in question["question_id"]:
                skip = "abstention"
            elif not has_target:
                skip = "no_target"
            jobs_out.write(json.dumps({"qid": question["question_id"], "query": question["question"], "docs": docs}) + "\n")
            gold_out.write(json.dumps({
                "qid": question["question_id"],
                "question_type": question["question_type"],
                "granularity": args.granularity,
                "corpus_ids": [doc["id"] for doc in docs],
                "correct": sorted({doc["id"] for doc in docs if "answer" in doc["id"]}),
                "skip": skip,
            }) + "\n")


if __name__ == "__main__":
    main()
