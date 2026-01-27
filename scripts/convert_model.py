import coremltools as ct
import torch
import transformers
from transformers import AutoModel, AutoTokenizer

# 1. Configuration
MODEL_ID = "sentence-transformers/all-MiniLM-L6-v2"
OUTPUT_PATH = "all-MiniLM-L6-v2.mlpackage"
MAX_SEQ_LENGTH = 512
BATCH_SIZE_RANGE = (1, 64)

print(f"Loading model: {MODEL_ID}...")

# 2. Load Model & Tokenizer
base_model = AutoModel.from_pretrained(MODEL_ID, torchscript=True)
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
        token_type_ids = torch.zeros_like(input_ids)
        return self.model(input_ids=input_ids, attention_mask=attention_mask, token_type_ids=token_type_ids)

model = ModelWrapper(base_model)
model.eval()

# 4. Create Dummy Input for Tracing
dummy_input_ids = torch.zeros((1, MAX_SEQ_LENGTH), dtype=torch.long)
dummy_attention_mask = torch.zeros((1, MAX_SEQ_LENGTH), dtype=torch.long)

# 5. Define Input Types with Dynamic Batch Dimension
batch_dim = ct.RangeDim(lower_bound=BATCH_SIZE_RANGE[0], 
                        upper_bound=BATCH_SIZE_RANGE[1], 
                        default=1)

input_tensors = [
    ct.TensorType(name="input_ids", shape=(batch_dim, MAX_SEQ_LENGTH), dtype=torch.int32),
    ct.TensorType(name="attention_mask", shape=(batch_dim, MAX_SEQ_LENGTH), dtype=torch.int32)
]

print("Converting model to Core ML with dynamic batching...")

# 6. Convert
# Trace with only 2 inputs
traced_model = torch.jit.trace(model, (dummy_input_ids, dummy_attention_mask))

mlmodel = ct.convert(
    traced_model,
    inputs=input_tensors,
    convert_to="mlprogram",
    minimum_deployment_target=ct.target.macOS13,
    compute_precision=ct.precision.FLOAT16
)

# 7. Set Metadata
mlmodel.author = "Wax Optimization Team"
mlmodel.license = "Apache 2.0"
mlmodel.short_description = "MiniLM-L6-v2 with dynamic batching (1-64). Inputs: input_ids, attention_mask."
mlmodel.version = "2.0"

# 8. Save
print(f"Saving to {OUTPUT_PATH}...")
mlmodel.save(OUTPUT_PATH)
print("✅ Done!")
