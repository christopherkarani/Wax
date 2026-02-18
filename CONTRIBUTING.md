# Contributing

## Production Readiness Gates

All production readiness checks are enforceable and must pass before merge.

### Local commands

Run from the repository root:

```bash
# Full quality gate (100% pass, no skipped tests, corruption assertion contract)
bash scripts/quality/production_readiness_gates.sh full

# Soak smoke gate (stability + WAL guardrail smoke)
bash scripts/quality/production_readiness_gates.sh soak-smoke

# Burn smoke gate (longer stability + WAL replay/open guardrail smoke)
bash scripts/quality/production_readiness_gates.sh burn-smoke
```

### Deterministic replay controls

Use these environment variables for runtime-sensitive stability tests:

```bash
# Load a fixed replay plan from disk
WAX_REPLAY_PATH=/absolute/path/replay-plan.json

# Generate deterministic plan from seed and iteration count
WAX_REPLAY_SEED=2026021801
WAX_REPLAY_ITERATIONS=700

# Record generated plan for exact future replay
WAX_REPLAY_RECORD_PATH=/absolute/path/replay-plan.json
```

### Stability budgets

Override stability budgets (defaults are profile-specific in the gate script):

```bash
WAX_STABILITY_MAX_RSS_GROWTH_MB=256
WAX_STABILITY_MAX_P50_DRIFT_PCT=140
WAX_STABILITY_MAX_P95_DRIFT_PCT=180
```
