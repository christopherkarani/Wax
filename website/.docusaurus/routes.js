import React from 'react';
import ComponentCreator from '@docusaurus/ComponentCreator';

export default [
  {
    path: '/docs',
    component: ComponentCreator('/docs', '699'),
    routes: [
      {
        path: '/docs',
        component: ComponentCreator('/docs', 'bdb'),
        routes: [
          {
            path: '/docs',
            component: ComponentCreator('/docs', '390'),
            routes: [
              {
                path: '/docs/architecture',
                component: ComponentCreator('/docs/architecture', '38d'),
                exact: true,
                sidebar: "docs"
              },
              {
                path: '/docs/core/concurrency-model',
                component: ComponentCreator('/docs/core/concurrency-model', 'ff3'),
                exact: true,
                sidebar: "docs"
              },
              {
                path: '/docs/core/file-format',
                component: ComponentCreator('/docs/core/file-format', '4d1'),
                exact: true,
                sidebar: "docs"
              },
              {
                path: '/docs/core/getting-started',
                component: ComponentCreator('/docs/core/getting-started', '628'),
                exact: true,
                sidebar: "docs"
              },
              {
                path: '/docs/core/structured-memory',
                component: ComponentCreator('/docs/core/structured-memory', '48c'),
                exact: true,
                sidebar: "docs"
              },
              {
                path: '/docs/core/wal-crash-recovery',
                component: ComponentCreator('/docs/core/wal-crash-recovery', '718'),
                exact: true,
                sidebar: "docs"
              },
              {
                path: '/docs/intro',
                component: ComponentCreator('/docs/intro', 'a6e'),
                exact: true,
                sidebar: "docs"
              },
              {
                path: '/docs/media/photo-rag',
                component: ComponentCreator('/docs/media/photo-rag', 'acd'),
                exact: true,
                sidebar: "docs"
              },
              {
                path: '/docs/media/video-rag',
                component: ComponentCreator('/docs/media/video-rag', 'ebf'),
                exact: true,
                sidebar: "docs"
              },
              {
                path: '/docs/mini-lm/mini-lm-embedder',
                component: ComponentCreator('/docs/mini-lm/mini-lm-embedder', 'ea3'),
                exact: true,
                sidebar: "docs"
              },
              {
                path: '/docs/orchestrator/memory-orchestrator',
                component: ComponentCreator('/docs/orchestrator/memory-orchestrator', 'b5e'),
                exact: true,
                sidebar: "docs"
              },
              {
                path: '/docs/orchestrator/rag-pipeline',
                component: ComponentCreator('/docs/orchestrator/rag-pipeline', '66a'),
                exact: true,
                sidebar: "docs"
              },
              {
                path: '/docs/orchestrator/session-management',
                component: ComponentCreator('/docs/orchestrator/session-management', 'f49'),
                exact: true,
                sidebar: "docs"
              },
              {
                path: '/docs/orchestrator/unified-search',
                component: ComponentCreator('/docs/orchestrator/unified-search', '996'),
                exact: true,
                sidebar: "docs"
              },
              {
                path: '/docs/text-search/text-search-engine',
                component: ComponentCreator('/docs/text-search/text-search-engine', 'd34'),
                exact: true,
                sidebar: "docs"
              },
              {
                path: '/docs/vector-search/embedding-providers',
                component: ComponentCreator('/docs/vector-search/embedding-providers', '5b4'),
                exact: true,
                sidebar: "docs"
              },
              {
                path: '/docs/vector-search/vector-search-engines',
                component: ComponentCreator('/docs/vector-search/vector-search-engines', '728'),
                exact: true,
                sidebar: "docs"
              }
            ]
          }
        ]
      }
    ]
  },
  {
    path: '/',
    component: ComponentCreator('/', '2e1'),
    exact: true
  },
  {
    path: '*',
    component: ComponentCreator('*'),
  },
];
