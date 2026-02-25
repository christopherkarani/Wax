/** @type {import('@docusaurus/plugin-content-docs').SidebarsConfig} */
const sidebars = {
  docs: [
    "intro",
    "architecture",
    {
      type: "category",
      label: "Orchestrator",
      items: [
        "orchestrator/memory-orchestrator",
        "orchestrator/rag-pipeline",
        "orchestrator/unified-search",
        "orchestrator/session-management",
      ],
    },
    {
      type: "category",
      label: "Media RAG",
      items: [
        "media/photo-rag",
        "media/video-rag",
      ],
    },
    {
      type: "category",
      label: "WaxCore",
      items: [
        "core/getting-started",
        "core/file-format",
        "core/wal-crash-recovery",
        "core/structured-memory",
        "core/concurrency-model",
      ],
    },
    {
      type: "category",
      label: "Text Search",
      items: [
        "text-search/text-search-engine",
      ],
    },
    {
      type: "category",
      label: "Vector Search",
      items: [
        "vector-search/vector-search-engines",
        "vector-search/embedding-providers",
      ],
    },
    {
      type: "category",
      label: "MiniLM Embedder",
      items: [
        "mini-lm/mini-lm-embedder",
      ],
    },
  ],
};

module.exports = sidebars;
