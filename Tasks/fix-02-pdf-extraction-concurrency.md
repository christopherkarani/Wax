Prompt:
Replace `Task.detached` usage in PDF extraction with structured concurrency.

Goal:
Preserve existing behavior and error handling while removing `Task.detached` in favor of structured concurrency.

Task Breakdown:
1. Locate the PDF extraction path and `Task.detached` usage.
2. Identify current concurrency behavior and error propagation expectations.
3. Replace with `Task {}`, `withTaskGroup`, or `async let` as appropriate, keeping behavior unchanged.
4. Ensure structured concurrency and `Sendable` safety.

Expected Output:
- PDF extraction uses structured concurrency only, with behavior and error handling preserved.
