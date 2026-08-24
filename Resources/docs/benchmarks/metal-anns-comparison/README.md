# MetalANNS 0.3.0 vs legacy Metal

Open `index.html` directly. Values are from `HybridVectorEngineBenchmark/testGPULargeNComparison` on 2026-08-24, Apple M3 Max, `swift test` Debug, MetalANNS `0.3.0`.

Warm query latency (ms), dim 384, cosine, top-24:

| Vectors | Legacy Metal | MetalANNS exact | MetalANNS `.fast` |
| ---: | ---: | ---: | ---: |
| 10 | 0.50 | 0.13 | 0.13 |
| 1,000 | 1.06 | 0.61 | 0.31 |
| 10,000 | 1.34 | 1.45 | 0.30 |
| 100,000 | 2.53 | 5.14 | 1.62 |
| 1,000,000 | 7.85 | 30.84 | 7.13 |
