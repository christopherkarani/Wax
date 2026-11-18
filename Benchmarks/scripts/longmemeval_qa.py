#!/usr/bin/env python3
"""LongMemEval end-to-end QA: build reader prompts, build judge prompts, score.

Follows the official LongMemEval code:
- reader prompt: src/generation/run_generation.py, history_format=json, CoT on,
  full sessions (user and assistant turns), sorted by session date, with the
  question date as "Current Date";
- judge prompts: src/evaluation/evaluate_qa.py get_anscheck_prompt, a response
  counts as correct when the judge's reply contains "yes".

Steps:
  reader  --data longmemeval_s_cleaned.json --context {retrieval,full,oracle}
          [--ranked wax-session.ranked.jsonl --top-k 5] [--oracle-data longmemeval_oracle.json]
          --out reader.requests.jsonl
  judge   --data ... --hypotheses reader.responses.jsonl --out judge.requests.jsonl
  score   --data ... --judgements judge.responses.jsonl [--json-out metrics.json]

Run each requests file through llm_run.py.
"""
import argparse
import json
from collections import defaultdict

COT_TEMPLATE = (
    "I will give you several history chats between you and a user. Please answer the question based on the "
    "relevant chat history. Answer the question step by step: first extract all the relevant information, and "
    "then reason over the information to get the answer.\n\n\nHistory Chats:\n\n{}\n\nCurrent Date: {}\n"
    "Question: {}\nAnswer (step by step):"
)

JUDGE_DEFAULT = (
    "I will give you a question, a correct answer, and a response from a model. Please answer yes if the response "
    "contains the correct answer. Otherwise, answer no. If the response is equivalent to the correct answer or "
    "contains all the intermediate steps to get the correct answer, you should also answer yes. If the response only "
    "contains a subset of the information required by the answer, answer no. \n\nQuestion: {}\n\nCorrect Answer: {}"
    "\n\nModel Response: {}\n\nIs the model response correct? Answer yes or no only."
)
JUDGE_TEMPORAL = (
    "I will give you a question, a correct answer, and a response from a model. Please answer yes if the response "
    "contains the correct answer. Otherwise, answer no. If the response is equivalent to the correct answer or "
    "contains all the intermediate steps to get the correct answer, you should also answer yes. If the response only "
    "contains a subset of the information required by the answer, answer no. In addition, do not penalize off-by-one "
    "errors for the number of days. If the question asks for the number of days/weeks/months, etc., and the model "
    "makes off-by-one errors (e.g., predicting 19 days when the answer is 18), the model's response is still correct. "
    "\n\nQuestion: {}\n\nCorrect Answer: {}\n\nModel Response: {}\n\nIs the model response correct? Answer yes or no only."
)
JUDGE_KNOWLEDGE_UPDATE = (
    "I will give you a question, a correct answer, and a response from a model. Please answer yes if the response "
    "contains the correct answer. Otherwise, answer no. If the response contains some previous information along with "
    "an updated answer, the response should be considered as correct as long as the updated answer is the required "
    "answer.\n\nQuestion: {}\n\nCorrect Answer: {}\n\nModel Response: {}\n\nIs the model response correct? Answer yes "
    "or no only."
)
JUDGE_PREFERENCE = (
    "I will give you a question, a rubric for desired personalized response, and a response from a model. Please "
    "answer yes if the response satisfies the desired response. Otherwise, answer no. The model does not need to "
    "reflect all the points in the rubric. The response is correct as long as it recalls and utilizes the user's "
    "personal information correctly.\n\nQuestion: {}\n\nRubric: {}\n\nModel Response: {}\n\nIs the model response "
    "correct? Answer yes or no only."
)
JUDGE_ABSTENTION = (
    "I will give you an unanswerable question, an explanation, and a response from a model. Please answer yes if the "
    "model correctly identifies the question as unanswerable. The model could say that the information is incomplete, "
    "or some other information is given but the asked information is not.\n\nQuestion: {}\n\nExplanation: {}\n\n"
    "Model Response: {}\n\nDoes the model correctly identify the question as unanswerable? Answer yes or no only."
)


def judge_template(question: dict) -> str:
    if "_abs" in question["question_id"]:
        return JUDGE_ABSTENTION
    return {
        "temporal-reasoning": JUDGE_TEMPORAL,
        "knowledge-update": JUDGE_KNOWLEDGE_UPDATE,
        "single-session-preference": JUDGE_PREFERENCE,
    }.get(question["question_type"], JUDGE_DEFAULT)


def strip_labels(session: list) -> list:
    return [{key: value for key, value in turn.items() if key != "has_answer"} for turn in session]


def history_string(chunks: list) -> str:
    """chunks: [(date, session)], rendered as in run_generation.py (json format)."""
    rendered = ""
    for index, (date, session) in enumerate(sorted(chunks, key=lambda chunk: chunk[0])):
        rendered += "\n### Session {}:\nSession Date: {}\nSession Content:\n{}\n".format(
            index + 1, date, "\n" + json.dumps(strip_labels(session))
        )
    return rendered


def load_jsonl(path: str) -> list:
    with open(path) as handle:
        return [json.loads(line) for line in handle]


def reader(args: argparse.Namespace) -> None:
    with open(args.data) as handle:
        questions = json.load(handle)
    ranked = {}
    if args.context == "retrieval":
        ranked = {entry["qid"]: entry["ranked"] for entry in load_jsonl(args.ranked)}
    oracle = {}
    if args.context == "oracle":
        with open(args.oracle_data) as handle:
            oracle = {entry["question_id"]: entry for entry in json.load(handle)}

    with open(args.out, "w") as out:
        for question in questions:
            if args.context == "oracle":
                source = oracle[question["question_id"]]
                chunks = list(zip(source["haystack_dates"], source["haystack_sessions"]))
            else:
                by_id = {
                    session_id: (date, session)
                    for session_id, date, session in zip(
                        question["haystack_session_ids"], question["haystack_dates"], question["haystack_sessions"]
                    )
                }
                if args.context == "full":
                    chunks = list(by_id.values())
                else:
                    session_ids = []
                    for doc_id in ranked[question["question_id"]]:
                        session_id = doc_id.replace("noans_", "answer_")
                        if session_id in by_id and session_id not in session_ids:
                            session_ids.append(session_id)
                        if len(session_ids) == args.top_k:
                            break
                    chunks = [by_id[session_id] for session_id in session_ids]
            prompt = COT_TEMPLATE.format(history_string(chunks), question["question_date"], question["question"])
            out.write(json.dumps({"id": question["question_id"], "prompt": prompt}) + "\n")


def judge(args: argparse.Namespace) -> None:
    with open(args.data) as handle:
        questions = {entry["question_id"]: entry for entry in json.load(handle)}
    with open(args.out, "w") as out:
        for hypothesis in load_jsonl(args.hypotheses):
            if hypothesis.get("error"):
                continue
            question = questions[hypothesis["id"]]
            prompt = judge_template(question).format(
                question["question"], question["answer"], hypothesis["response"]
            )
            out.write(json.dumps({"id": hypothesis["id"], "prompt": prompt}) + "\n")


def score(args: argparse.Namespace) -> None:
    with open(args.data) as handle:
        questions = {entry["question_id"]: entry for entry in json.load(handle)}
    judged = {entry["id"]: entry for entry in load_jsonl(args.judgements) if not entry.get("error")}
    missing = [qid for qid in questions if qid not in judged]
    by_type = defaultdict(list)
    labels = []
    for qid, entry in judged.items():
        label = 1 if "yes" in entry["response"].lower() else 0
        labels.append(label)
        qtype = "abstention" if "_abs" in qid else questions[qid]["question_type"]
        by_type[qtype].append(label)
    non_abstention_types = [qtype for qtype in by_type if qtype != "abstention"]
    report = {
        "judged": len(labels),
        "missing": len(missing),
        "accuracy": sum(labels) / len(labels),
        "task_averaged_accuracy": sum(sum(by_type[t]) / len(by_type[t]) for t in non_abstention_types)
        / len(non_abstention_types),
        "per_type": {qtype: {"accuracy": sum(values) / len(values), "n": len(values)} for qtype, values in by_type.items()},
    }
    if args.json_out:
        with open(args.json_out, "w") as handle:
            json.dump(report, handle, indent=2)
    print(json.dumps(report, indent=2))


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = parser.add_subparsers(dest="command", required=True)
    reader_parser = sub.add_parser("reader")
    reader_parser.add_argument("--data", required=True)
    reader_parser.add_argument("--context", choices=["retrieval", "full", "oracle"], required=True)
    reader_parser.add_argument("--ranked")
    reader_parser.add_argument("--top-k", type=int, default=5)
    reader_parser.add_argument("--oracle-data")
    reader_parser.add_argument("--out", required=True)
    judge_parser = sub.add_parser("judge")
    judge_parser.add_argument("--data", required=True)
    judge_parser.add_argument("--hypotheses", required=True)
    judge_parser.add_argument("--out", required=True)
    score_parser = sub.add_parser("score")
    score_parser.add_argument("--data", required=True)
    score_parser.add_argument("--judgements", required=True)
    score_parser.add_argument("--json-out")
    args = parser.parse_args()
    {"reader": reader, "judge": judge, "score": score}[args.command](args)


if __name__ == "__main__":
    main()
