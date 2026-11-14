#!/usr/bin/env python3
"""mem0 (open-source `mem0ai`) on LoCoMo, for the same QA protocol as the Wax rows.

Ingest mirrors mem0's own LoCoMo evaluation (mem0ai/mem0 evaluation/src/memzero/add.py,
commit aae5989e): each conversation gets two users, one per speaker; every session is
added to both, two messages per `add` call, with the session date as `timestamp`
metadata. For speaker A's user, A's turns are `user` messages and B's are `assistant`
messages; speaker B's user gets the reverse. Search mirrors evaluation/src/memzero/search.py:
the question is searched in both users' memories, top_k per user (30 in mem0's runs).

Differences from mem0's published run, all forced by running locally:
- the open-source `Memory` class (mem0ai 2.x: one extraction call per `add`, hybrid
  semantic + BM25 + entity search) instead of the hosted platform (`MemoryClient`), with
  the run's platform custom instructions passed as `custom_instructions`, and each
  session's date passed as the extraction prompt's observation date (the platform's
  `timestamp`; see install_observation_date_patch);
- the extraction and update LLM is claude-haiku-5-5 through `claude -p` (no tools, no
  settings), not gpt-4o-mini;
- local embeddings (sentence-transformers all-MiniLM-L6-v2, 384-d) and mem0's local
  default vector store (Qdrant, on disk), not OpenAI text-embedding-3-small.

Steps:
  ingest  --data locomo10.json --store-dir DIR [--convs 0,1] [--workers 20]
          (resumable per conversation/speaker; writes DIR/llm_calls.jsonl)
  search  --data locomo10.json --gold gold.jsonl --store-dir DIR --top-k 30 --out memories.jsonl
  reader  --gold gold.jsonl --memories memories.jsonl --out reader.jsonl [--prompt wax|mem0]
          wax:  the reader prompt and system prompt every other LoCoMo row uses
                (locomo.py), context lines "<timestamp> | <speaker>: <memory>", both
                users' memories in timestamp order;
          mem0: mem0's own ANSWER_PROMPT (evaluation/prompts.py) as the system message.
Then llm_run.py (haiku), locomo.py judge, llm_run.py (sonnet), locomo.py score, as for Wax.
"""
from __future__ import annotations

import argparse
import json
import os
import re
import subprocess
import sys
import tempfile
import threading
import time
from concurrent.futures import ThreadPoolExecutor, as_completed
from datetime import datetime
from pathlib import Path

os.environ.setdefault("MEM0_TELEMETRY", "False")
os.environ.setdefault("ANONYMIZED_TELEMETRY", "False")
os.environ.setdefault("TOKENIZERS_PARALLELISM", "false")

sys.path.insert(0, str(Path(__file__).resolve().parent))
import locomo  # noqa: E402  (READER_SYSTEM, READER_PROMPT, load_jsonl)

EMBED_MODEL = "sentence-transformers/all-MiniLM-L6-v2"
EMBED_DIMS = 384
LLM_MODEL = "claude-haiku-5-5"
BATCH_SIZE = 2

# evaluation/src/memzero/add.py `custom_instructions` at commit aae5989e (verbatim).
CUSTOM_INSTRUCTIONS = """
Generate personal memories that follow these guidelines:

1. Each memory should be self-contained with complete context, including:
   - The person's name, do not use "user" while creating memories
   - Personal details (career aspirations, hobbies, life circumstances)
   - Emotional states and reactions
   - Ongoing journeys or future plans
   - Specific dates when events occurred

2. Include meaningful personal narratives focusing on:
   - Identity and self-acceptance journeys
   - Family planning and parenting
   - Creative outlets and hobbies
   - Mental health and self-care activities
   - Career aspirations and education goals
   - Important life events and milestones

3. Make each memory rich with specific details rather than general statements
   - Include timeframes (exact dates when possible)
   - Name specific activities (e.g., "charity race for mental health" rather than just "exercise")
   - Include emotional context and personal growth elements

4. Extract memories only from user messages, not incorporating assistant responses

5. Format each memory as a paragraph with a clear narrative structure that captures the person's experience, challenges, and aspirations
"""

# mem0 evaluation/prompts.py ANSWER_PROMPT at commit aae5989e, rendered with str.format
# instead of jinja2 (same text).
MEM0_ANSWER_PROMPT = """
    You are an intelligent memory assistant tasked with retrieving accurate information from conversation memories.

    # CONTEXT:
    You have access to memories from two speakers in a conversation. These memories contain
    timestamped information that may be relevant to answering the question.

    # INSTRUCTIONS:
    1. Carefully analyze all provided memories from both speakers
    2. Pay special attention to the timestamps to determine the answer
    3. If the question asks about a specific event or fact, look for direct evidence in the memories
    4. If the memories contain contradictory information, prioritize the most recent memory
    5. If there is a question about time references (like "last year", "two months ago", etc.),
       calculate the actual date based on the memory timestamp. For example, if a memory from
       4 May 2022 mentions "went to India last year," then the trip occurred in 2021.
    6. Always convert relative time references to specific dates, months, or years. For example,
       convert "last year" to "2022" or "two months ago" to "March 2023" based on the memory
       timestamp. Ignore the reference while answering the question.
    7. Focus only on the content of the memories from both speakers. Do not confuse character
       names mentioned in memories with the actual users who created those memories.
    8. The answer should be less than 5-6 words.

    # APPROACH (Think step by step):
    1. First, examine all memories that contain information related to the question
    2. Examine the timestamps and content of these memories carefully
    3. Look for explicit mentions of dates, times, locations, or events that answer the question
    4. If the answer requires calculation (e.g., converting relative time references), show your work
    5. Formulate a precise, concise answer based solely on the evidence in the memories
    6. Double-check that your answer directly addresses the question asked
    7. Ensure your final answer is specific and avoids vague time references

    Memories for user {speaker_1_user_id}:

    {speaker_1_memories}

    Memories for user {speaker_2_user_id}:

    {speaker_2_memories}

    Question: {question}

    Answer:
    """


# ---------------------------------------------------------------------------
# LLM adapter: mem0's LLM interface over `claude -p`.

class CallLog:
    def __init__(self, path: Path):
        self.path = path
        self.lock = threading.Lock()

    def write(self, entry: dict) -> None:
        with self.lock, open(self.path, "a") as handle:
            handle.write(json.dumps(entry) + "\n")


def claude_call(system: str, prompt: str, model: str, workdir: str, timeout_s: int = 600) -> dict:
    command = [
        "claude", "-p",
        "--model", model,
        "--system-prompt", system,
        "--tools", "",
        "--setting-sources", "",
        "--strict-mcp-config",
        "--disable-slash-commands",
        "--no-session-persistence",
        "--output-format", "json",
    ]
    completed = subprocess.run(
        command, input=prompt, capture_output=True, text=True, cwd=workdir, timeout=timeout_s, check=False
    )
    if completed.returncode != 0 and not completed.stdout.strip():
        raise RuntimeError(f"claude exited {completed.returncode}: {completed.stderr.strip()[:300]}")
    payload = json.loads(completed.stdout)
    if payload.get("is_error"):
        raise RuntimeError(f"claude error: {str(payload.get('result'))[:300]}")
    return payload


def make_llm_class(base):
    class ClaudeCLILLM(base):
        """mem0 LLM backed by `claude -p`; retries with backoff, logs every call."""

        def __init__(self, model: str, workdir: str, log: CallLog, stream: str):
            # Skip LLMBase.__init__: it builds a provider config this adapter does not need.
            self.model = model
            self.workdir = workdir
            self.log = log
            self.stream = stream

        def generate_response(self, messages, response_format=None, tools=None, tool_choice="auto", **kwargs):
            if tools:
                raise NotImplementedError("tool calls are only used by mem0's graph memory")
            system_parts = [m["content"] for m in messages if m["role"] == "system"]
            other = [m for m in messages if m["role"] != "system"]
            system = "\n\n".join(system_parts) or "You are a helpful assistant."
            if len(other) == 1:
                prompt = other[0]["content"]
            else:
                prompt = "\n\n".join(f"{m['role']}: {m['content']}" for m in other)
            if response_format and response_format.get("type") == "json_object":
                prompt += "\n\nRespond with only the JSON object, no other text."
            delay = 5.0
            attempt = 0
            while True:
                attempt += 1
                started = time.time()
                try:
                    payload = claude_call(system, prompt, self.model, self.workdir)
                    usage = payload.get("usage", {})
                    self.log.write({
                        "stream": self.stream,
                        "ok": True,
                        "seconds": round(time.time() - started, 2),
                        "input_tokens": usage.get("input_tokens", 0)
                        + usage.get("cache_read_input_tokens", 0)
                        + usage.get("cache_creation_input_tokens", 0),
                        "output_tokens": usage.get("output_tokens", 0),
                    })
                    return payload.get("result", "")
                except (RuntimeError, json.JSONDecodeError, subprocess.TimeoutExpired) as error:
                    self.log.write({"stream": self.stream, "ok": False, "error": str(error)[:300], "attempt": attempt})
                    if "authenticate" in str(error):
                        # An expired `claude` login lasts until someone logs in again: wait for it
                        # instead of failing the stream (the add has written nothing yet).
                        time.sleep(300)
                        continue
                    if attempt >= 7:
                        raise
                    time.sleep(delay)
                    delay = min(delay * 2, 300)

    return ClaudeCLILLM


# ---------------------------------------------------------------------------
# Observation date.
#
# mem0's extraction prompt has an "Observation Date" that relative references ("yesterday",
# "last week") are grounded to. The hosted platform sets it from `add(timestamp=...)`; the
# open-source `add` rejects `timestamp` and leaves it at today's date, which would date every
# LoCoMo memory to the day of the run. This patch passes each session's date instead, as the
# platform would.

_observation = threading.local()


def install_observation_date_patch() -> None:
    import mem0.memory.main as mem0_main

    original = mem0_main.generate_additive_extraction_prompt

    def with_observation_date(*args, **kwargs):
        date = getattr(_observation, "date", None)
        if date and kwargs.get("timestamp") is None:
            kwargs["timestamp"] = date
        return original(*args, **kwargs)

    mem0_main.generate_additive_extraction_prompt = with_observation_date


# ---------------------------------------------------------------------------
# Stores.

_embedder_lock = threading.Lock()
_shared_embedder = None


def open_memory(store_dir: Path, user_id: str, llm=None):
    """One mem0 Memory per user, each with its own on-disk Qdrant directory and history DB."""
    from mem0 import Memory

    global _shared_embedder
    user_dir = store_dir / "users" / user_id
    user_dir.mkdir(parents=True, exist_ok=True)
    config = {
        "embedder": {"provider": "huggingface", "config": {"model": EMBED_MODEL, "embedding_dims": EMBED_DIMS}},
        "vector_store": {
            "provider": "qdrant",
            "config": {
                "collection_name": "mem0",
                "path": str(user_dir / "qdrant"),
                "embedding_model_dims": EMBED_DIMS,
                "on_disk": True,
            },
        },
        "history_db_path": str(user_dir / "history.db"),
        # The custom instructions mem0's LoCoMo run set on its platform project (add.py).
        "custom_instructions": CUSTOM_INSTRUCTIONS,
    }
    # mem0 accepts only its own provider names here. The OpenAI client is constructed but
    # never called (no network at construction); memory.llm is replaced below.
    config["llm"] = {"provider": "openai", "config": {"model": "unused", "api_key": "unused"}}
    memory = Memory.from_config(config)
    with _embedder_lock:
        if _shared_embedder is None:
            _shared_embedder = memory.embedding_model
    memory.embedding_model = _shared_embedder
    if llm is not None:
        memory.llm = llm
    return memory


def user_ids(conversation: dict, index: int) -> tuple[str, str]:
    return f"{conversation['speaker_a']}_{index}", f"{conversation['speaker_b']}_{index}"


def session_keys(conversation: dict) -> list[str]:
    numbers = sorted(int(k.split("_")[1]) for k in conversation if re.fullmatch(r"session_\d+", k))
    return [f"session_{n}" for n in numbers]


def ingest_stream(args, sample: dict, index: int, which: str, llm_class, log: CallLog, workdir: str) -> dict:
    conversation = sample["conversation"]
    speaker_a, speaker_b = conversation["speaker_a"], conversation["speaker_b"]
    user_a, user_b = user_ids(conversation, index)
    user_id = user_a if which == "a" else user_b
    store_dir = Path(args.store_dir)
    done_marker = store_dir / "users" / user_id / "DONE"
    if done_marker.exists():
        return {"user": user_id, "skipped": True}
    progress_path = store_dir / "users" / user_id / "progress.json"
    llm = llm_class(LLM_MODEL, workdir, log, user_id)
    memory = open_memory(store_dir, user_id, llm)
    progress = json.loads(progress_path.read_text()) if progress_path.exists() else {"batches_done": 0}
    batch_counter = 0
    started = time.time()
    for key in session_keys(conversation):
        timestamp = conversation[f"{key}_date_time"]
        _observation.date = parse_locomo_date(timestamp).date().isoformat()
        messages = []
        for chat in conversation[key]:
            own = chat["speaker"] == (speaker_a if which == "a" else speaker_b)
            if chat["speaker"] not in (speaker_a, speaker_b):
                raise ValueError(f"unknown speaker {chat['speaker']}")
            messages.append({"role": "user" if own else "assistant", "content": f"{chat['speaker']}: {chat['text']}"})
        for start in range(0, len(messages), BATCH_SIZE):
            batch_counter += 1
            if batch_counter <= progress["batches_done"]:
                continue
            memory.add(messages[start:start + BATCH_SIZE], user_id=user_id, metadata={"timestamp": timestamp})
            progress["batches_done"] = batch_counter
            progress_path.write_text(json.dumps(progress))
    done_marker.write_text(json.dumps({"batches": batch_counter, "seconds": round(time.time() - started, 1)}))
    return {"user": user_id, "batches": batch_counter, "seconds": round(time.time() - started, 1)}


def ingest(args) -> None:
    from mem0.llms.base import LLMBase

    samples = json.load(open(args.data))
    convs = [int(c) for c in args.convs.split(",")] if args.convs else list(range(len(samples)))
    store_dir = Path(args.store_dir)
    store_dir.mkdir(parents=True, exist_ok=True)
    log = CallLog(store_dir / "llm_calls.jsonl")
    llm_class = make_llm_class(LLMBase)
    install_observation_date_patch()
    started = time.time()
    with tempfile.TemporaryDirectory(prefix="mem0-llm-") as workdir, ThreadPoolExecutor(args.workers) as pool:
        futures = [
            pool.submit(ingest_stream, args, samples[i], i, which, llm_class, log, workdir)
            for i in convs for which in ("a", "b")
        ]
        for future in as_completed(futures):
            print(json.dumps(future.result()), flush=True)
    print(json.dumps({"ingest_wall_seconds": round(time.time() - started, 1)}), flush=True)


# ---------------------------------------------------------------------------
# Search and reader.

def search(args) -> None:
    samples = json.load(open(args.data))
    gold = locomo.load_jsonl(args.gold)
    store_dir = Path(args.store_dir)
    done = set()
    if os.path.exists(args.out):
        done = {entry["qid"] for entry in locomo.load_jsonl(args.out)}
    only = {int(c) for c in args.convs.split(",")} if args.convs else None
    by_conv: dict[int, list] = {}
    for entry in gold:
        if entry["qid"] not in done and (only is None or entry["conv"] in only):
            by_conv.setdefault(entry["conv"], []).append(entry)
    with open(args.out, "a") as out:
        for conv, entries in sorted(by_conv.items()):
            conversation = samples[conv]["conversation"]
            ids = user_ids(conversation, conv)
            memories = {uid: open_memory(store_dir, uid) for uid in ids}
            for entry in entries:
                record = {"qid": entry["qid"], "users": []}
                for uid in ids:
                    t0 = time.perf_counter()
                    result = memories[uid].search(entry["question"], top_k=args.top_k, filters={"user_id": uid})
                    ms = (time.perf_counter() - t0) * 1000
                    items = result["results"] if isinstance(result, dict) else result
                    record["users"].append({
                        "user": uid,
                        "search_ms": round(ms, 2),
                        "memories": [
                            {"memory": m["memory"], "timestamp": (m.get("metadata") or {}).get("timestamp", ""),
                             "score": round(float(m.get("score") or 0), 4)}
                            for m in items
                        ],
                    })
                out.write(json.dumps(record) + "\n")
                out.flush()
            for memory in memories.values():
                client = getattr(memory.vector_store, "client", None)
                if client is not None and hasattr(client, "close"):
                    client.close()


def parse_locomo_date(text: str) -> datetime:
    # LoCoMo session dates look like "1:56 pm on 8 May, 2023".
    try:
        return datetime.strptime(text.strip(), "%I:%M %p on %d %B, %Y")
    except ValueError:
        return datetime.max


def reader(args) -> None:
    gold = {entry["qid"]: entry for entry in locomo.load_jsonl(args.gold)}
    with open(args.out, "w") as out:
        for record in locomo.load_jsonl(args.memories):
            entry = gold[record["qid"]]
            if args.prompt == "wax":
                rows = []
                for user in record["users"]:
                    speaker = user["user"].rsplit("_", 1)[0]
                    rows.extend((parse_locomo_date(m["timestamp"]), m["timestamp"], speaker, m["memory"])
                                for m in user["memories"])
                rows.sort(key=lambda row: row[0])
                context = "".join(f"{date} | {speaker}: {memory}\n" for _, date, speaker, memory in rows)
                prompt = locomo.READER_PROMPT.format(question=entry["question"], context=context)
                out.write(json.dumps({"id": record["qid"], "system": locomo.READER_SYSTEM, "prompt": prompt}) + "\n")
            else:
                lines = [[f"{m['timestamp']}: {m['memory']}" for m in user["memories"]] for user in record["users"]]
                system = MEM0_ANSWER_PROMPT.format(
                    speaker_1_user_id=record["users"][0]["user"].split("_")[0],
                    speaker_2_user_id=record["users"][1]["user"].split("_")[0],
                    speaker_1_memories=json.dumps(lines[0], indent=4),
                    speaker_2_memories=json.dumps(lines[1], indent=4),
                    question=entry["question"],
                )
                # mem0 sends the whole prompt as the system message; `claude -p` needs a user turn.
                out.write(json.dumps({"id": record["qid"], "system": system, "prompt": entry["question"]}) + "\n")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = parser.add_subparsers(dest="command", required=True)
    p = sub.add_parser("ingest")
    p.add_argument("--data", required=True)
    p.add_argument("--store-dir", required=True)
    p.add_argument("--convs", help="comma-separated conversation indexes (default: all)")
    p.add_argument("--workers", type=int, default=20)
    p = sub.add_parser("search")
    p.add_argument("--data", required=True)
    p.add_argument("--gold", required=True)
    p.add_argument("--store-dir", required=True)
    p.add_argument("--top-k", type=int, default=30)
    p.add_argument("--convs", help="comma-separated conversation indexes (default: all)")
    p.add_argument("--out", required=True)
    p = sub.add_parser("reader")
    p.add_argument("--gold", required=True)
    p.add_argument("--memories", required=True)
    p.add_argument("--out", required=True)
    p.add_argument("--prompt", choices=["wax", "mem0"], default="wax")
    args = parser.parse_args()
    {"ingest": ingest, "search": search, "reader": reader}[args.command](args)


if __name__ == "__main__":
    main()
