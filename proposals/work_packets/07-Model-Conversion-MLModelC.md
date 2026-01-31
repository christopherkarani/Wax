Prompt:
Own the Core ML model conversion pipeline for all-MiniLM-L6-v2 with dynamic batching, and ship a compiled .mlmodelc resource in the Swift package.

Goal:
A repeatable, documented conversion + shipping workflow that produces a dynamic-batch Core ML model, validates output shapes, and embeds the compiled .mlmodelc in `WaxVectorSearchMiniLM` resources.

Task BreakDown:
- Review and harden `scripts/convert_model.py` (RangeDim for batch, float16, mlprogram) and ensure output is a .mlpackage with correct inputs/outputs.
- Add a compile step to produce `.mlmodelc` (e.g., `xcrun coremlc compile`) and document the expected output path.
- Replace `Sources/WaxVectorSearchMiniLM/Resources/all-MiniLM-L6-v2.mlpackage` (if present) with the compiled `.mlmodelc` directory.
- Verify `MiniLMEmbeddings` loads `all-MiniLM-L6-v2.mlmodelc` from `Bundle.module` and fails loudly if missing.
- Update `MODEL_CONVERSION.md` with the full conversion + compile + shipping steps, including validation commands and sanity checks.
