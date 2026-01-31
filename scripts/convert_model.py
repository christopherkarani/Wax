import argparse
import coremltools as ct
import numpy as np
import torch
from transformers import AutoModel, AutoTokenizer

try:
    from coremltools.optimize.coreml import linear_quantize_weights
except Exception:  # pragma: no cover - optional dependency
    linear_quantize_weights = None

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

# Optional post-training weight quantization
if args.quantize != "none":
    if linear_quantize_weights is None:
        raise RuntimeError("coremltools.optimize.coreml is unavailable; cannot quantize.")
    nbits = 8 if args.quantize == "int8" else 4
    print(f"Applying weight quantization: {nbits}-bit...")
    mlmodel = linear_quantize_weights(mlmodel, nbits=nbits)

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
