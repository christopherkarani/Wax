# Changelog

## Unreleased

- MiniLM now uses sentence-transformers mean pooling and reports the embedding identity `MiniLMAll-mean`. Stores written by the old `MiniLMAll` pooler are re-embedded automatically (resumable; text search keeps working meanwhile) and then rebound to `MiniLMAll-mean`. Once a store is rebound, older `wax-cli` / `wax-mcp` builds refuse to open it with a model-binding mismatch. Upgrade every host that shares the store. To re-embed a copy explicitly, run `wax-cli embed-backfill --direct-store --store-path <store> --output <copy>`.
