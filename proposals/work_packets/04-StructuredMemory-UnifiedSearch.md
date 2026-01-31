Prompt:
Integrate structured memory into `Wax.search` (always-on). Add a deterministic structured-memory candidate lane that surfaces evidence frames and fuses them via RRF. Add `asOfMs` to `SearchRequest` with a deterministic default (`Int64.max`).

Goal:
Determinism tests guarantee stable results and tie-breaks for the always-on structured-memory lane, and `.structuredMemory` is present when evidence causes a hit.

Task BreakDown:
- Add request option + response source.
- Implement alias→entity→facts→evidenceFrames path.
- Add stable ranking/tie-breaks and tests.
