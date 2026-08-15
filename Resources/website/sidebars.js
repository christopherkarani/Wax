/** @type {import('@docusaurus/plugin-content-docs').SidebarsConfig} */
const sidebars = {
  docs: [
    "intro",
    {
      type: "category",
      label: "iOS apps",
      collapsed: false,
      items: [
        "ios/getting-started",
        "ios/foundation-models",
        "ios/memory-api",
      ],
    },
    "architecture",
    {
      type: "category",
      label: "Internals (contributors)",
      collapsed: true,
      items: [
        "orchestrator/memory-orchestrator",
        "orchestrator/rag-pipeline",
        "orchestrator/unified-search",
        "orchestrator/session-management",
        "media/photo-rag",
        "media/video-rag",
        "core/getting-started",
        "core/file-format",
        "core/wal-crash-recovery",
        "core/structured-memory",
        "core/concurrency-model",
        "text-search/text-search-engine",
        "vector-search/vector-search-engines",
        "vector-search/embedding-providers",
        "mini-lm/mini-lm-embedder",
      ],
    },
  ],
};

module.exports = sidebars;
