import argparse
import coremltools as ct
import numpy as np
import torch
from transformers import AutoModel, AutoTokenizer

try:
    import coremltools.optimize as cto
except Exception:  # pragma: no cover - optional dependency
    cto = None

# 1. Configuration
MODEL_ID = "sentence-transformers/all-MiniLM-L6-v2"
DEFAULT_OUTPUT_PATH = "all-MiniLM-L6-v2.mlpackage"
DEFAULT_MAX_SEQ_LENGTH = 512
DEFAULT_MIN_SEQ_LENGTH = 8
DEFAULT_BATCH_RANGE = (1, 64)
DEFAULT_BATCH_SIZES = [1, 8, 16, 32, 64]
DEFAULT_SEQ_LENGTHS = [32, 64, 128, 256, 384, 512]

parser = argparse.ArgumentParser(description="Convert MiniLM to Core ML with dynamic batch/sequence lengths.")
parser.add_argument("--output", default=DEFAULT_OUTPUT_PATH, help="Output .mlpackage path")
parser.add_argument("--max-seq", type=int, default=DEFAULT_MAX_SEQ_LENGTH, help="Max sequence length (for tracing)")
parser.add_argument("--min-seq", type=int, default=DEFAULT_MIN_SEQ_LENGTH, help="Min sequence length (RangeDim only)")
parser.add_argument("--max-batch", type=int, default=DEFAULT_BATCH_RANGE[1], help="Max batch size (RangeDim only)")
parser.add_argument("--min-batch", type=int, default=DEFAULT_BATCH_RANGE[0], help="Min batch size (RangeDim only)")
parser.add_argument("--enumerated-shapes", action="store_true", help="Use EnumeratedShapes for batch/sequence lengths")
parser.add_argument("--batch-sizes", type=str, default=",".join(str(x) for x in DEFAULT_BATCH_SIZES), help="Comma-separated batch sizes for EnumeratedShapes")
parser.add_argument("--seq-lengths", type=str, default=",".join(str(x) for x in DEFAULT_SEQ_LENGTHS), help="Comma-separated sequence lengths for EnumeratedShapes")
parser.add_argument("--quantize", choices=["none", "int8", "int4"], default="none", help="Optional weight quantization")
parser.add_argument("--quantize-granularity", choices=["per_tensor", "per_channel", "per_block"], default="per_channel")
parser.add_argument("--quantize-block-size", type=int, default=32, help="Block size for per_block quantization")
parser.add_argument("--palettize-nbits", type=int, default=None, help="Enable palettization with nbits (e.g. 4)")
parser.add_argument("--palettize-mode", choices=["kmeans", "uniform", "unique"], default="kmeans")
parser.add_argument("--palettize-granularity", choices=["per_tensor", "per_grouped_channel"], default="per_grouped_channel")
parser.add_argument("--palettize-group-size", type=int, default=16)
parser.add_argument("--palettize-cluster-dim", type=int, default=1)
parser.add_argument("--palettize-per-channel-scale", action="store_true")
parser.add_argument("--joint-compression", action="store_true", help="Enable joint compression when applying multiple passes")
parser.add_argument("--activation-quantize", action="store_true", help="Enable activation quantization (W8A8) with calibration data")
parser.add_argument("--calibration-sentences-file", type=str, default=None, help="Path to newline-separated calibration sentences")
parser.add_argument("--calibration-samples", type=int, default=16, help="Number of calibration samples to use")
parser.add_argument("--calibration-op-group-size", type=int, default=-1, help="Activation quantization op group size")
parser.add_argument("--attn-implementation", choices=["eager", "sdpa"], default="eager", help="Attention implementation for conversion")
args = parser.parse_args()

OUTPUT_PATH = args.output
MAX_SEQ_LENGTH = args.max_seq
SEQ_LENGTH_RANGE = (args.min_seq, args.max_seq)
BATCH_SIZE_RANGE = (args.min_batch, args.max_batch)

print(f"Loading model: {MODEL_ID}...")

# 2. Load Model & Tokenizer
base_model = AutoModel.from_pretrained(MODEL_ID, attn_implementation=args.attn_implementation)
base_model.config.return_dict = False
tokenizer = AutoTokenizer.from_pretrained(MODEL_ID)
base_model.eval()

# 3. Create Wrapper for 2-Input Compatibility
# The existing Swift code only provides input_ids and attention_mask.
# We must handle token_type_ids internally to maintain drop-in compatibility.
class ModelWrapper(torch.nn.Module):
    def __init__(self, model):
        super().__init__()
        self.model = model
    
    def forward(self, input_ids, attention_mask):
        # Create token_type_ids (zeros) on the fly matching input device/shape
        input_ids = input_ids.to(torch.long)
        attention_mask = attention_mask.to(torch.long)
        token_type_ids = torch.zeros_like(input_ids)
        outputs = self.model(
            input_ids=input_ids,
            attention_mask=attention_mask,
            token_type_ids=token_type_ids,
            return_dict=False,
        )
        # Return pooled output (CLS) for sentence embeddings
        return outputs[1]

model = ModelWrapper(base_model)
model.eval()

# 4. Create Dummy Input for Tracing
dummy_input_ids = torch.zeros((1, MAX_SEQ_LENGTH), dtype=torch.int32)
dummy_attention_mask = torch.zeros((1, MAX_SEQ_LENGTH), dtype=torch.int32)

if args.enumerated_shapes:
    batch_sizes = [int(x) for x in args.batch_sizes.split(",") if x]
    seq_lengths = [int(x) for x in args.seq_lengths.split(",") if x]
    shapes = [(b, s) for b in batch_sizes for s in seq_lengths]
    enum_shape = ct.EnumeratedShapes(shapes=shapes)
    input_tensors = [
        ct.TensorType(name="input_ids", shape=enum_shape, dtype=np.int32),
        ct.TensorType(name="attention_mask", shape=enum_shape, dtype=np.int32),
    ]
else:
    # 5. Define Input Types with Dynamic Batch/Sequence Dimensions
    batch_dim = ct.RangeDim(
        lower_bound=BATCH_SIZE_RANGE[0],
        upper_bound=BATCH_SIZE_RANGE[1],
        default=BATCH_SIZE_RANGE[0],
    )
    seq_dim = ct.RangeDim(
        lower_bound=SEQ_LENGTH_RANGE[0],
        upper_bound=SEQ_LENGTH_RANGE[1],
        default=MAX_SEQ_LENGTH,
    )
    input_tensors = [
        ct.TensorType(name="input_ids", shape=(batch_dim, seq_dim), dtype=np.int32),
        ct.TensorType(name="attention_mask", shape=(batch_dim, seq_dim), dtype=np.int32),
    ]

print("Converting model to Core ML with dynamic batching...")

# 6. Convert
# Trace with only 2 inputs
traced_model = torch.jit.trace(model, (dummy_input_ids, dummy_attention_mask))

mlmodel = ct.convert(
    traced_model,
    inputs=input_tensors,
    convert_to="mlprogram",
    minimum_deployment_target=ct.target.macOS15,
    compute_precision=ct.precision.FLOAT16
)

def _load_calibration_sentences() -> list[str]:
    if args.calibration_sentences_file:
        with open(args.calibration_sentences_file, "r", encoding="utf-8") as handle:
            lines = [line.strip() for line in handle.readlines()]
        return [line for line in lines if line]
    return [
        "Swift concurrency makes structured parallelism practical.",
        "Vector search underpins modern retrieval-augmented generation.",
        "Core ML optimizations should balance accuracy and throughput.",
        "Batch embeddings improve ANE utilization on Apple silicon.",
        "Memory systems need fast ingestion and recall latencies.",
        "Structured logging helps debug RAG pipelines.",
        "Compression techniques like quantization reduce bandwidth.",
        "On-device inference keeps user data private."
    ]


def _build_calibration_data(samples: int) -> list[dict[str, np.ndarray]]:
    sentences = _load_calibration_sentences()
    if not sentences:
        raise RuntimeError("No calibration sentences available.")
    selected = sentences[:samples]
    calibration_data = []
    for sentence in selected:
        encoded = tokenizer(
            sentence,
            padding="max_length",
            truncation=True,
            max_length=MAX_SEQ_LENGTH,
            return_tensors="np",
        )
        calibration_data.append({
            "input_ids": encoded["input_ids"].astype(np.int32),
            "attention_mask": encoded["attention_mask"].astype(np.int32),
        })
    return calibration_data


if args.activation_quantize:
    if cto is None or not hasattr(cto.coreml, "experimental"):
        raise RuntimeError("coremltools.optimize.coreml.experimental is unavailable; cannot activation-quantize.")
    print("Applying activation quantization (A8) with calibration data...")
    activation_config = cto.coreml.OptimizationConfig(
        global_config=cto.coreml.OpLinearQuantizerConfig(mode="linear_symmetric")
    )
    calibration_data = _build_calibration_data(args.calibration_samples)
    if args.calibration_op_group_size > 0:
        mlmodel = cto.coreml.experimental.linear_quantize_activations(
            mlmodel,
            activation_config,
            calibration_data,
            calibration_op_group_size=args.calibration_op_group_size,
        )
    else:
        mlmodel = cto.coreml.experimental.linear_quantize_activations(
            mlmodel,
            activation_config,
            calibration_data,
        )

if args.palettize_nbits is not None:
    if cto is None:
        raise RuntimeError("coremltools.optimize.coreml is unavailable; cannot palettize.")
    print(f"Applying palettization: {args.palettize_mode} {args.palettize_nbits}-bit...")
    pal_kwargs = {
        "mode": args.palettize_mode,
        "nbits": args.palettize_nbits,
        "granularity": args.palettize_granularity,
        "cluster_dim": args.palettize_cluster_dim,
        "enable_per_channel_scale": args.palettize_per_channel_scale,
    }
    if args.palettize_granularity == "per_grouped_channel":
        pal_kwargs["group_size"] = args.palettize_group_size
    pal_config = cto.coreml.OptimizationConfig(
        global_config=cto.coreml.OpPalettizerConfig(**pal_kwargs)
    )
    try:
        mlmodel = cto.coreml.palettize_weights(mlmodel, pal_config, joint_compression=args.joint_compression)
    except ModuleNotFoundError as exc:
        raise RuntimeError("Palettization requires scikit-learn for k-means. Install scikit-learn or use --palettize-mode uniform/unique.") from exc

if args.quantize != "none":
    if cto is None:
        raise RuntimeError("coremltools.optimize.coreml is unavailable; cannot quantize.")
    dtype = "int8" if args.quantize == "int8" else "int4"
    print(f"Applying weight quantization: {dtype} ({args.quantize_granularity})...")
    quant_kwargs = {
        "mode": "linear_symmetric",
        "dtype": dtype,
        "granularity": args.quantize_granularity,
    }
    if args.quantize_granularity == "per_block":
        quant_kwargs["block_size"] = args.quantize_block_size
    quant_config = cto.coreml.OptimizationConfig(
        global_config=cto.coreml.OpLinearQuantizerConfig(**quant_kwargs)
    )
    mlmodel = cto.coreml.linear_quantize_weights(mlmodel, quant_config, joint_compression=args.joint_compression)

# 7. Set Metadata
mlmodel.author = "Wax Optimization Team"
mlmodel.license = "Apache 2.0"
mlmodel.short_description = (
    "MiniLM-L6-v2 with dynamic batching/sequence length. Inputs: input_ids, attention_mask."
)
mlmodel.version = "2.0"

# 8. Save
print(f"Saving to {OUTPUT_PATH}...")
mlmodel.save(OUTPUT_PATH)
print("✅ Done!")
