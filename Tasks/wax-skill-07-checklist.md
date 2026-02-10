Prompt:
You are the Test-First Agent. Produce a validation checklist for the skill content.

Goal:
Create a short checklist that ensures the skill aligns with sources, type safety, and constraints.

Task Breakdown:
- Verify every API claim is supported by `Sources/Wax`.
- Verify constraints are supported by `README.md` or tests.
- Confirm examples compile conceptually (signatures, throws, async).
- Ensure no new claims without evidence.

Expected Output:
A concise checklist (markdown) to be used before review and release.
