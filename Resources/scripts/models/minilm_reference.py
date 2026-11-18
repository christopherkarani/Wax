"""Shared reference pipeline for the bundled all-MiniLM-L6-v2 Core ML model.

The reference reproduces sentence-transformers/all-MiniLM-L6-v2 exactly:
BERT tokenizer (truncated at max_seq_length=256), BertModel last_hidden_state,
masked mean pooling, L2 normalization. Weights are pinned to a Hugging Face
revision and verified by SHA-256 before use.

Pinned toolchain (see requirements-minilm.txt): torch 2.7.1, transformers 4.57.6,
tokenizers 0.22.x, coremltools 9.0, huggingface_hub.
"""
from __future__ import annotations

import hashlib
from pathlib import Path

import numpy as np
import torch
from safetensors.torch import load_file
from tokenizers import Tokenizer
from transformers import BertConfig, BertModel

REPO_ID = "sentence-transformers/all-MiniLM-L6-v2"
REVISION = "1110a243fdf4706b3f48f1d95db1a4f5529b4d41"
SAFETENSORS_SHA256 = "53aa51172d142c89d9012cce15ae4d6cc0ca6895895114379cacb4fab128d9db"
# sentence_bert_config.json at REVISION: {"max_seq_length": 256}
MAX_SEQ_LENGTH = 256
HIDDEN_SIZE = 384

# Published sentence-transformers values for "This is an example sentence" (first 8 dims).
ANCHOR_SENTENCE = "This is an example sentence"
ANCHOR_PREFIX = [0.067657, 0.063496, 0.048713, 0.079305, 0.037448, 0.002653, 0.039375, -0.007098]


def _sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for block in iter(lambda: handle.read(1 << 20), b""):
            digest.update(block)
    return digest.hexdigest()


def resolve_weights(weights_dir: str | None) -> Path:
    """Return a directory holding model.safetensors + tokenizer.json at REVISION."""
    if weights_dir:
        directory = Path(weights_dir)
    else:
        from huggingface_hub import hf_hub_download

        safetensors = hf_hub_download(REPO_ID, "model.safetensors", revision=REVISION)
        hf_hub_download(REPO_ID, "tokenizer.json", revision=REVISION)
        directory = Path(safetensors).parent
    actual = _sha256(directory / "model.safetensors")
    if actual != SAFETENSORS_SHA256:
        raise SystemExit(f"model.safetensors sha256 {actual} != pinned {SAFETENSORS_SHA256}")
    return directory


def bert_config() -> BertConfig:
    return BertConfig(
        vocab_size=30522,
        hidden_size=HIDDEN_SIZE,
        num_hidden_layers=6,
        num_attention_heads=12,
        intermediate_size=1536,
        max_position_embeddings=512,
        hidden_act="gelu",
        attn_implementation="eager",
    )


def load_backbone(directory: Path) -> BertModel:
    state = load_file(str(directory / "model.safetensors"))
    state = {k: v for k, v in state.items() if not k.startswith("pooler.") and k != "embeddings.position_ids"}
    model = BertModel(bert_config(), add_pooling_layer=False)
    model.load_state_dict(state, strict=True)
    return model.eval()


def load_tokenizer(directory: Path) -> Tokenizer:
    tokenizer = Tokenizer.from_file(str(directory / "tokenizer.json"))
    tokenizer.no_padding()
    tokenizer.enable_truncation(max_length=MAX_SEQ_LENGTH)
    return tokenizer


def reference_embeddings(backbone: BertModel, tokenizer: Tokenizer, sentences: list[str]) -> np.ndarray:
    """sentence-transformers semantics: masked mean of last_hidden_state, then L2 normalize."""
    rows = []
    for sentence in sentences:
        encoding = tokenizer.encode(sentence)
        ids = torch.tensor([encoding.ids])
        mask = torch.tensor([encoding.attention_mask])
        with torch.no_grad():
            hidden = backbone(input_ids=ids, attention_mask=mask).last_hidden_state[0]
        weights = mask[0].unsqueeze(-1).to(hidden.dtype)
        pooled = ((hidden * weights).sum(0) / weights.sum()).double().numpy()
        rows.append(pooled / np.linalg.norm(pooled))
    return np.asarray(rows, dtype=np.float64)


def check_anchor(backbone: BertModel, tokenizer: Tokenizer) -> None:
    vector = reference_embeddings(backbone, tokenizer, [ANCHOR_SENTENCE])[0]
    if not np.allclose(vector[: len(ANCHOR_PREFIX)], ANCHOR_PREFIX, atol=1e-5):
        raise SystemExit(f"reference anchor mismatch: {vector[:8]} vs {ANCHOR_PREFIX}")
