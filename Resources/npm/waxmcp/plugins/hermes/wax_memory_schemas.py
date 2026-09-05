"""Hermes tool schemas and name sets for the Wax memory provider."""

from __future__ import annotations

from typing import Any, Dict, List, Optional

WAX_MEMORY_TYPES = [
    "note",
    "task_state",
    "user_preference",
    "decision",
    "lesson",
    "handoff",
    "constraint",
    "fact",
]
CORE_TOOL_NAMES = {
    "wax_remember",
    "wax_recall",
    "wax_search",
    "wax_handoff",
    "wax_handoff_latest",
    "wax_stats",
}
STRUCTURED_TOOL_NAMES = {
    "wax_entity_upsert",
    "wax_entity_resolve",
    "wax_fact_assert",
    "wax_fact_retract",
    "wax_facts_query",
}
EXTENDED_TOOL_NAMES = {
    "wax_compact_context",
    "wax_markdown_export",
    "wax_markdown_sync",
    "wax_knowledge_capture",
    "wax_corpus_search",
    "wax_promote",
}
TOOLS_WITH_SESSION_ID = {
    "remember",
    "recall",
    "search",
    "handoff",
    "compact_context",
    "markdown_export",
    "session_start",
    "session_end",
    "session_resume",
    "session_synthesize",
    "memory_append",
    "memory_search",
    "memory_promote",
    "promote",
    "knowledge_capture",
}


def _schema(
    name: str,
    description: str,
    properties: Dict[str, Any],
    required: Optional[List[str]] = None,
) -> Dict[str, Any]:
    return {
        "name": name,
        "description": description,
        "parameters": {
            "type": "object",
            "properties": properties,
            "required": required or [],
            "additionalProperties": False,
        },
    }


TOOL_SCHEMAS = {
    "wax_remember": _schema(
        "wax_remember",
        "Store durable or working memory in Wax. Use for facts, decisions, lessons, and preferences.",
        {
            "content": {"type": "string", "description": "Text content to store."},
            "metadata": {"type": "object", "additionalProperties": True},
            "memory_type": {"type": "string", "enum": WAX_MEMORY_TYPES},
            "durability": {"type": "string", "enum": ["ephemeral", "working", "durable", "locked"]},
            "project": {"type": "string"},
            "repo": {"type": "string"},
            "confidence": {"type": "number", "minimum": 0.0, "maximum": 1.0},
            "expires_in_days": {"type": "integer", "minimum": 1, "maximum": 3650},
            "reviewed": {"type": "boolean"},
            "locked": {"type": "boolean"},
        },
        ["content"],
    ),
    "wax_recall": _schema(
        "wax_recall",
        "Recall context from Wax using RAG assembly. Use text for recent or exact facts; use hybrid only when embeddings are available.",
        {
            "query": {"type": "string"},
            "limit": {"type": "integer", "minimum": 1, "maximum": 100},
            "mode": {"type": "string", "enum": ["text", "vector", "hybrid"]},
            "alpha": {"type": "number", "minimum": 0.0, "maximum": 1.0},
            "scope": {
                "type": "string",
                "enum": ["project", "session", "global"],
                "description": "Project is the default relevance scope; global searches every project and is not an authorization boundary.",
            },
            "project": {"type": "string"},
            "repo": {
                "type": "string",
                "description": "Exact repo filter; when project is also supplied, both must match.",
            },
            "cwd": {"type": "string"},
            "search_top_k": {"type": "integer", "minimum": 1, "maximum": 200},
        },
        ["query"],
    ),
    "wax_search": _schema(
        "wax_search",
        "Run direct Wax search and return ranked raw hits.",
        {
            "query": {"type": "string"},
            "mode": {"type": "string", "enum": ["text", "vector", "hybrid"]},
            "topK": {"type": "integer", "minimum": 1, "maximum": 200},
            "alpha": {"type": "number", "minimum": 0.0, "maximum": 1.0},
        },
        ["query"],
    ),
    "wax_handoff": _schema(
        "wax_handoff",
        "Store a cross-session handoff note for later retrieval.",
        {
            "content": {"type": "string"},
            "project": {"type": "string"},
            "pending_tasks": {"type": "array", "items": {"type": "string"}},
        },
        ["content"],
    ),
    "wax_handoff_latest": _schema(
        "wax_handoff_latest",
        "Fetch the latest handoff note, optionally scoped by project.",
        {"project": {"type": "string"}},
    ),
    "wax_stats": _schema("wax_stats", "Return Wax runtime and storage statistics.", {}),
    "wax_entity_upsert": _schema(
        "wax_entity_upsert",
        "Upsert a structured-memory entity by key.",
        {
            "key": {"type": "string"},
            "kind": {"type": "string"},
            "aliases": {"type": "array", "items": {"type": "string"}},
        },
        ["key", "kind"],
    ),
    "wax_entity_resolve": _schema(
        "wax_entity_resolve",
        "Resolve a structured-memory entity by alias.",
        {"alias": {"type": "string"}, "limit": {"type": "integer", "minimum": 1, "maximum": 100}},
        ["alias"],
    ),
    "wax_fact_assert": _schema(
        "wax_fact_assert",
        "Assert a structured-memory fact (S-P-O triple).",
        {
            "subject": {"type": "string"},
            "predicate": {"type": "string"},
            "object": {"description": "Fact value: string, number, boolean, or typed object."},
            "relation": {"type": "string", "enum": ["sets", "updates", "extends", "retracts"]},
            "valid_from": {"type": "integer"},
            "valid_to": {"type": "integer"},
        },
        ["subject", "predicate", "object"],
    ),
    "wax_fact_retract": _schema(
        "wax_fact_retract",
        "Retract a structured-memory fact by id.",
        {"fact_id": {"type": "integer", "minimum": 0}, "at_ms": {"type": "integer"}},
        ["fact_id"],
    ),
    "wax_facts_query": _schema(
        "wax_facts_query",
        "Query structured-memory facts by subject, predicate, or time.",
        {
            "subject": {"type": "string"},
            "predicate": {"type": "string"},
            "as_of": {"type": "integer"},
            "system_as_of": {"type": "integer"},
            "valid_as_of": {"type": "integer"},
            "limit": {"type": "integer", "minimum": 1, "maximum": 500},
        },
    ),
    "wax_compact_context": _schema(
        "wax_compact_context",
        "Assemble short, medium, and long-horizon memory into a token-budgeted checkpoint.",
        {
            "query": {"type": "string"},
            "token_budget": {"type": "integer", "minimum": 128, "maximum": 32000},
            "max_items": {"type": "integer", "minimum": 1, "maximum": 64},
            "mode": {"type": "string", "enum": ["text", "vector", "hybrid"]},
            "alpha": {"type": "number", "minimum": 0.0, "maximum": 1.0},
        },
        ["query"],
    ),
    "wax_markdown_export": _schema(
        "wax_markdown_export",
        "Export Markdown projections (MEMORY.md, daily notes) from Wax.",
        {"output_dir": {"type": "string"}},
        ["output_dir"],
    ),
    "wax_markdown_sync": _schema(
        "wax_markdown_sync",
        "Import and reconcile Markdown projections back into Wax.",
        {"root_dir": {"type": "string"}, "dry_run": {"type": "boolean"}},
        ["root_dir"],
    ),
    "wax_session_start": _schema(
        "wax_session_start",
        "Create a broker-managed virtual session.",
        {"session_id": {"type": "string"}, "agent_id": {"type": "string"}, "run_id": {"type": "string"}},
    ),
    "wax_session_end": _schema(
        "wax_session_end",
        "End an active broker-managed virtual session.",
        {"session_id": {"type": "string"}},
    ),
    "wax_session_resume": _schema(
        "wax_session_resume",
        "Resume an existing broker-managed virtual session.",
        {"session_id": {"type": "string"}},
        ["session_id"],
    ),
    "wax_session_synthesize": _schema(
        "wax_session_synthesize",
        "Summarize the active session into handoff, lessons, and promotion candidates.",
        {"session_id": {"type": "string"}, "max_candidates": {"type": "integer", "minimum": 1, "maximum": 12}},
    ),
    "wax_knowledge_capture": _schema(
        "wax_knowledge_capture",
        "Capture durable knowledge from a natural statement.",
        {
            "content": {"type": "string"},
            "memory_type": {"type": "string", "enum": WAX_MEMORY_TYPES},
            "kind": {"type": "string"},
        },
        ["content"],
    ),
    "wax_corpus_search": _schema(
        "wax_corpus_search",
        "Search broker-managed session history with provenance.",
        {
            "query": {"type": "string"},
            "limit": {"type": "integer", "minimum": 1, "maximum": 50},
        },
        ["query"],
    ),
    "wax_promote": _schema(
        "wax_promote",
        "Promote a working memory into durable memory.",
        {"frame_id": {"type": "integer"}},
    ),
}
