"""Convert all-MiniLM-L6-v2 to the bundled Core ML model.

Usage:
    python Resources/scripts/models/convert_minilm.py OUT.mlpackage [--weights-dir DIR]
    xcrun coremlcompiler compile OUT.mlpackage Sources/WaxVectorSearchMiniLM/Resources/

The graph returns `embeddings` [batch, 384]: the masked mean of last_hidden_state
(sentence-transformers Pooling mode_mean_tokens). L2 normalization stays in Swift.

The attention mask is applied as `(1 - mask) * -1e4`, not Hugging Face's
`finfo(float32).min`: that constant becomes -inf when the Neural Engine runs in
Float16, and `0 * -inf` turns padded rows into NaN.

Before saving, the converted model is checked against the PyTorch reference
(cosine >= 0.9999 on CPU, finite on CPU and Neural Engine) and the published
sentence-transformers anchor values.
"""
from __future__ import annotations

import argparse

import coremltools as ct
import numpy as np
import torch

import minilm_reference as ref

BATCH_SIZES = (1, 8, 16, 32, 64)
SEQUENCE_LENGTHS = (32, 64, 128, 256)  # ref.MAX_SEQ_LENGTH caps the input
MASK_FILL = -1.0e4


class MeanPooledMiniLM(torch.nn.Module):
    def __init__(self, backbone: torch.nn.Module):
        super().__init__()
        self.backbone = backbone

    def forward(self, input_ids: torch.Tensor, attention_mask: torch.Tensor) -> torch.Tensor:
        mask = attention_mask.to(torch.float32)
        additive = (1.0 - mask[:, None, None, :]) * MASK_FILL
        hidden = self.backbone.embeddings(input_ids=input_ids)
        hidden = self.backbone.encoder(hidden, attention_mask=additive).last_hidden_state
        weights = mask.unsqueeze(-1)
        summed = (hidden * weights).sum(dim=1)
        counts = weights.sum(dim=1).clamp(min=1e-9)
        return summed / counts


def convert(module: torch.nn.Module) -> ct.models.MLModel:
    example = (torch.zeros((1, 32), dtype=torch.int32), torch.ones((1, 32), dtype=torch.int32))
    with torch.no_grad():
        traced = torch.jit.trace(module, example)
    shapes = [[b, s] for b in BATCH_SIZES for s in SEQUENCE_LENGTHS]
    inputs = [
        ct.TensorType(name=name, shape=ct.EnumeratedShapes(shapes=shapes, default=[1, 32]), dtype=np.int32)
        for name in ("input_ids", "attention_mask")
    ]
    model = ct.convert(
        traced,
        inputs=inputs,
        outputs=[ct.TensorType(name="embeddings", dtype=np.float32)],
        compute_precision=ct.precision.FLOAT32,
        minimum_deployment_target=ct.target.iOS18,
        convert_to="mlprogram",
    )
    model.short_description = (
        "all-MiniLM-L6-v2 sentence embeddings (mean pooled over attention_mask, not L2-normalized). "
        f"Inputs: input_ids, attention_mask, up to {ref.MAX_SEQ_LENGTH} tokens."
    )
    model.author = "Wax"
    model.license = "Apache 2.0"
    model.version = "5.0"
    model.output_description["embeddings"] = "Mean-pooled sentence embedding [batch, 384]."
    model.user_defined_metadata["wax.minilm.compute_precision"] = "FLOAT32"
    model.user_defined_metadata["wax.minilm.pooling"] = "mean"
    model.user_defined_metadata["wax.minilm.max_seq_length"] = str(ref.MAX_SEQ_LENGTH)
    model.user_defined_metadata["wax.minilm.mask_fill"] = str(MASK_FILL)
    model.user_defined_metadata["wax.minilm.source"] = f"{ref.REPO_ID}@{ref.REVISION}"
    return model


def padded_inputs(tokenizer, sentences: list[str], length: int, batch: int) -> dict[str, np.ndarray]:
    """Rows past len(sentences) stay fully masked, like padded batch slots."""
    ids = np.zeros((batch, length), dtype=np.int32)
    mask = np.zeros_like(ids)
    for row, sentence in enumerate(sentences):
        encoded = tokenizer.encode(sentence).ids
        ids[row, : len(encoded)] = encoded
        mask[row, : len(encoded)] = 1
    return {"input_ids": ids, "attention_mask": mask}


def verify(path: str, backbone, tokenizer) -> None:
    sentences = [
        ref.ANCHOR_SENTENCE,
        "hi",
        "Wax keeps agent memory in a single portable file.",
        " ".join(["Long inputs are truncated at the sentence-transformers limit."] * 40),
    ]
    expected = ref.reference_embeddings(backbone, tokenizer, sentences)
    for units in (ct.ComputeUnit.CPU_ONLY, ct.ComputeUnit.CPU_AND_NE):
        compiled = ct.models.MLModel(path, compute_units=units)
        for length in SEQUENCE_LENGTHS:
            fitting = [s for s in sentences if len(tokenizer.encode(s).ids) <= length]
            # Wax predicts one sentence at a time (MiniLMEmbedder.maximumCoreMLPredictionBatchSize).
            # Batched Neural Engine prediction crashes inside Core ML on some OS builds, so
            # batch > 1 is only checked on CPU.
            batches = (1, BATCH_SIZES[1]) if units is ct.ComputeUnit.CPU_ONLY else (1,)
            for batch in batches:
                groups = [[s] for s in fitting] if batch == 1 else [fitting]
                for group in groups:
                    if not group:
                        continue
                    for _ in range(10):
                        raw = compiled.predict(padded_inputs(tokenizer, group, length, batch))["embeddings"]
                        out = np.asarray(raw, dtype=np.float64)
                        if not np.isfinite(out).all():
                            raise SystemExit(f"non-finite output on {units.name} at batch {batch} seq {length}")
                    if units is ct.ComputeUnit.CPU_ONLY:
                        rows = out[: len(group)]
                        rows /= np.linalg.norm(rows, axis=1, keepdims=True)
                        cosine = (rows * expected[[sentences.index(s) for s in group]]).sum(axis=1)
                        if cosine.min() < 0.9999:
                            raise SystemExit(f"CPU cosine vs reference {cosine.min():.6f} at seq {length}")
    print("verified: finite on CPU_ONLY and CPU_AND_NE; CPU cosine >= 0.9999 vs reference")


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("output", help="Destination .mlpackage")
    parser.add_argument("--weights-dir", help="Local directory with model.safetensors + tokenizer.json")
    parser.add_argument("--verify-only", action="store_true", help="Only re-run checks on an existing output")
    args = parser.parse_args()

    directory = ref.resolve_weights(args.weights_dir)
    backbone = ref.load_backbone(directory)
    tokenizer = ref.load_tokenizer(directory)
    ref.check_anchor(backbone, tokenizer)

    if not args.verify_only:
        model = convert(MeanPooledMiniLM(backbone).eval())
        model.save(args.output)
    verify(args.output, backbone, tokenizer)
    print("saved", args.output)


if __name__ == "__main__":
    main()
