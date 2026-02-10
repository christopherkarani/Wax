Prompt:
Fix PhotoRAG location allowlist behavior for radiusMeters <= 0.

Goal:
Ensure radius <= 0 does not filter out all frames.

Task Breakdown:
1. Update buildLocationAllowlist to return nil for radius <= 0.
2. Adjust caller to only apply FrameFilter when allowlist is non-nil.

Expected Output:
- Location filtering no longer excludes all frames when radius <= 0.
