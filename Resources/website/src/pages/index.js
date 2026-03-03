import React, { useEffect, useRef, useState } from "react";
import Layout from "@theme/Layout";
import CodeBlock from "@theme/CodeBlock";
import Link from "@docusaurus/Link";

/* ── Data ── */
const stats = [
  { label: "warm metal search",  value: "0.85ms",  desc: "p50 latency @ 10K docs on Apple Silicon GPU" },
  { label: "serialization",      value: "117x",    desc: "buffer save vs file-based — faster writes"   },
  { label: "embedding speed",    value: "193/sec", desc: "texts per second with MiniLM batch=16"       },
  { label: "network calls",      value: "0",       desc: "100% on-device. zero cloud dependency."      },
];

const features = [
  {
    num: "01",
    title: "remember anything",
    desc: "store memory frames with metadata. crash-safe wal writes. content-dedup via sha-256. zero indexing overhead.",
  },
  {
    num: "02",
    title: "recall in 0.85ms",
    desc: "hybrid bm25 + metal gpu vector search. deterministic results — same query returns same context, every time.",
  },
  {
    num: "03",
    title: "plug into claude",
    desc: "one command wires wax as claude code's persistent memory. every session remembers what matters.",
  },
];

const comparison = [
  { feature: "warm search @ 10K",  wax: "0.85ms", chroma: "~20ms",      pgvector: "~15ms",  pinecone: "~50-100ms" },
  { feature: "works offline",      wax: true,     chroma: true,          pgvector: true,     pinecone: false       },
  { feature: "zero servers",       wax: true,     chroma: false,         pgvector: false,    pinecone: false       },
  { feature: "single file",        wax: true,     chroma: false,         pgvector: false,    pinecone: false       },
  { feature: "crash-safe writes",  wax: true,     chroma: false,         pgvector: "partial",pinecone: "n/a"       },
  { feature: "gpu vector search",  wax: true,     chroma: false,         pgvector: false,    pinecone: false       },
  { feature: "swift native",       wax: true,     chroma: false,         pgvector: false,    pinecone: false       },
  { feature: "deterministic rag",  wax: true,     chroma: false,         pgvector: false,    pinecone: false       },
];

const perfBars = [
  { label: "wax metal (warm)",  value: 1.22,  max: 100, unit: "ms", isWax: true  },
  { label: "wax metal (cold)",  value: 71.63, max: 100, unit: "ms", isWax: true  },
  { label: "pgvector (hnsw)",   value: 15,    max: 100, unit: "ms", isWax: false },
  { label: "chroma local",      value: 20,    max: 100, unit: "ms", isWax: false },
  { label: "pinecone (cloud)",  value: 100,   max: 100, unit: "ms", isWax: false },
];

const cliDemo = `$ waxmcp remember "user prefers dark mode, gets headaches from bright screens"
✓ stored (frame #1247, hybrid index updated, 0.3ms)

$ waxmcp recall "user preferences" --limit 3
→ user prefers dark mode, gets headaches from bright screens
→ user is on macos 15, uses xcode daily
→ user timezone: america/chicago

$ waxmcp search "display settings" --mode hybrid
→ 3 results (1.22ms)`;

const swiftDemo = `import Wax

// open a hybrid store with on-device embeddings (minilm, 384-dim)
let brain = try await MemoryOrchestrator.openMiniLM(
    at: URL(fileURLWithPath: "brain.wax")
)

// remember something
try await brain.remember(
    "user prefers dark mode and gets headaches from bright screens",
    metadata: ["source": "onboarding"]
)

// recall with rag — deterministic, 0.85ms warm
let context = try await brain.recall(query: "user preferences")`;

const mcpInstallDemo = `$ waxmcp mcp install --scope user
✓ registered wax as mcp server in claude code
  store: ~/.wax/memory.wax
  tools: remember, recall, search, entity-upsert, facts-query

# claude code now has persistent memory across every session`;

/* ── Components ── */

function CellValue({ val }) {
  if (val === true)      return <span className="check-mark">✓</span>;
  if (val === false)     return <span className="cross-mark">✕</span>;
  if (val === "partial") return <span className="partial-txt">partial</span>;
  if (val === "n/a")     return <span className="partial-txt">n/a</span>;
  return <span style={{ color: "var(--accent)", fontWeight: 600 }}>{val}</span>;
}

function CopyButton({ text }) {
  const [copied, setCopied] = useState(false);
  const handleCopy = () => {
    navigator.clipboard.writeText(text).catch(() => {});
    setCopied(true);
    setTimeout(() => setCopied(false), 2000);
  };
  return (
    <button className={`copy-btn${copied ? " copied" : ""}`} onClick={handleCopy}>
      {copied ? "copied!" : "copy"}
    </button>
  );
}

function PerfSection() {
  const [animated, setAnimated] = useState(false);
  const ref = useRef(null);

  useEffect(() => {
    const el = ref.current;
    if (!el || typeof IntersectionObserver === "undefined") { setAnimated(true); return; }
    const obs = new IntersectionObserver(
      ([e]) => { if (e.isIntersecting) setAnimated(true); },
      { threshold: 0.2 }
    );
    obs.observe(el);
    return () => obs.disconnect();
  }, []);

  return (
    <section className="perf-section" ref={ref}>
      <span className="section-eyebrow">benchmarks</span>
      <h2 className="section-heading">vector search latency</h2>
      <p className="section-subheading">wax vs. alternatives at 10K docs on apple silicon</p>

      {perfBars.map((bar, i) => (
        <div className="perf-bar-container" key={bar.label}>
          <div className="perf-bar-label">
            <span className={`perf-label-name${bar.isWax ? " is-wax" : ""}`}>{bar.label}</span>
            <span className="perf-label-value">{bar.value}{bar.unit}</span>
          </div>
          <div className="perf-bar-track">
            <div
              className={`perf-bar-fill${bar.isWax ? " is-wax" : ""}`}
              style={{
                width: animated ? `${(bar.value / bar.max) * 100}%` : "0%",
                transitionDelay: animated ? `${i * 0.12}s` : "0s",
              }}
            />
          </div>
        </div>
      ))}

      <div className="perf-stats-row">
        <div>
          <div className="perf-stat-value">1.22ms</div>
          <div className="perf-stat-label">warm metal search</div>
        </div>
        <div>
          <div className="perf-stat-value">58.6x</div>
          <div className="perf-stat-label">warm vs cold speedup</div>
        </div>
        <div>
          <div className="perf-stat-value">89.3/s</div>
          <div className="perf-stat-label">docs/sec ingest</div>
        </div>
      </div>
    </section>
  );
}

function DemoSection() {
  const [tab, setTab] = useState("cli");
  return (
    <section className="cli-section">
      <span className="section-eyebrow">quick start</span>
      <h2 className="section-heading">two lines to get started</h2>
      <p className="section-subheading">cli for scripts and claude integration. swift api for your app.</p>

      <div>
        <div className="demo-tabs">
          <button className={`demo-tab${tab === "cli" ? " active" : ""}`} onClick={() => setTab("cli")}>cli</button>
          <button className={`demo-tab${tab === "swift" ? " active" : ""}`} onClick={() => setTab("swift")}>swift</button>
        </div>
        <div className="demo-panel">
          {tab === "cli" ? (
            <CodeBlock language="bash">{cliDemo}</CodeBlock>
          ) : (
            <div>
              <div style={{
                background: "var(--bg-elevated)",
                border: "1px solid var(--border-faint)",
                borderBottom: "none",
                borderRadius: "2px 2px 0 0",
                display: "flex",
                alignItems: "center",
                gap: "7px",
                padding: "10px 14px",
              }}>
                <div style={{ width: 10, height: 10, borderRadius: "50%", background: "#EF4444" }} />
                <div style={{ width: 10, height: 10, borderRadius: "50%", background: "#F97316" }} />
                <div style={{ width: 10, height: 10, borderRadius: "50%", background: "#10B981" }} />
                <span style={{ fontFamily: "var(--font-mono)", fontSize: "0.7rem", color: "var(--text-muted)", marginLeft: 4 }}>brain.swift</span>
              </div>
              <CodeBlock language="swift">{swiftDemo}</CodeBlock>
            </div>
          )}
        </div>
      </div>
    </section>
  );
}

/* ── Main export ── */
export default function Home() {
  return (
    <Layout description="On-device RAG for Swift. One file. Zero servers.">

      {/* ── Hero ── */}
      <section className="hero-section">
        <div className="hero-status">
          <span className="hero-status-dot" />
          v2 live
        </div>
        <div className="hero-eyebrow">on-device rag for swift</div>
        <h1 className="hero-title">wax</h1>
        <div className="hero-rule" />
        <p className="hero-subtitle">
          documents, embeddings, bm25 and hnsw indexes in a single file.
          no docker. no network calls. no cloud.
        </p>
        <div className="hero-buttons">
          <Link className="btn-primary" to="/docs/intro">get started →</Link>
          <Link className="btn-ghost" href="https://github.com/christopherkarani/Wax">github →</Link>
        </div>
      </section>

      {/* ── Install strip ── */}
      <div className="install-strip">
        <div className="install-cmd">
          <span className="install-cmd-prefix">$</span>
          brew install waxmcp
          <CopyButton text="brew install waxmcp" />
        </div>
        <div className="install-sub">
          or: <code>waxmcp mcp install --scope user</code> to plug into claude code
        </div>
      </div>

      {/* ── Stats strip ── */}
      <section className="stats-section">
        <div className="stats-strip">
          {stats.map((s) => (
            <div className="stat-item" key={s.label}>
              <div className="stat-label">{s.label}</div>
              <div className="stat-value">{s.value}</div>
              <div className="stat-desc">{s.desc}</div>
            </div>
          ))}
        </div>
      </section>

      {/* ── Feature cards ── */}
      <section className="features-section">
        <span className="section-eyebrow">capabilities</span>
        <h2 className="section-heading">everything you need. nothing you don't.</h2>
        <p className="section-subheading" style={{ marginBottom: "2rem" }}>built for swift developers shipping on-device ai.</p>
        <div className="features-grid">
          {features.map((f) => (
            <div className="feature-card" key={f.num}>
              <span className="feature-number">{f.num}</span>
              <h3 className="feature-heading">{f.title}</h3>
              <p className="feature-desc">{f.desc}</p>
            </div>
          ))}
        </div>
      </section>

      {/* ── CLI + Swift demo ── */}
      <DemoSection />

      {/* ── MCP / Claude integration ── */}
      <section className="mcp-section">
        <div className="mcp-card">
          <div className="mcp-text">
            <span className="section-eyebrow section-eyebrow-left">claude code integration</span>
            <h2 className="section-heading section-heading-left">plug wax into claude in one command</h2>
            <p className="section-subheading section-sub-left" style={{ marginBottom: 0 }}>
              wax becomes claude's persistent memory. every conversation remembers context across sessions —
              preferences, decisions, knowledge graph, all of it.
            </p>
          </div>
          <div className="mcp-code">
            <CodeBlock language="bash">{mcpInstallDemo}</CodeBlock>
          </div>
        </div>
      </section>

      {/* ── Performance ── */}
      <PerfSection />

      {/* ── Comparison ── */}
      <section className="comparison-section">
        <span className="section-eyebrow">how it compares</span>
        <h2 className="section-heading">wax vs. the alternatives</h2>
        <p className="section-subheading">for ios/macos developers building on-device ai.</p>

        <table>
          <thead>
            <tr>
              <th style={{ textAlign: "left" }}>feature</th>
              <th className="wax-col" style={{ textAlign: "center" }}>wax</th>
              <th style={{ textAlign: "center" }}>chroma</th>
              <th style={{ textAlign: "center" }}>pgvector</th>
              <th style={{ textAlign: "center" }}>pinecone</th>
            </tr>
          </thead>
          <tbody>
            {comparison.map((row) => (
              <tr key={row.feature}>
                <td>{row.feature}</td>
                <td className="wax-col" style={{ textAlign: "center" }}><CellValue val={row.wax} /></td>
                <td style={{ textAlign: "center" }}><CellValue val={row.chroma} /></td>
                <td style={{ textAlign: "center" }}><CellValue val={row.pgvector} /></td>
                <td style={{ textAlign: "center" }}><CellValue val={row.pinecone} /></td>
              </tr>
            ))}
          </tbody>
        </table>
        <p style={{ fontSize: "0.72rem", color: "var(--text-muted)", marginTop: "1rem", textAlign: "center", fontFamily: "var(--font-mono)" }}>
          competitor numbers are typical/publicly cited values, not head-to-head lab measurements.
        </p>
      </section>

      <div style={{ height: "5rem" }} />
    </Layout>
  );
}
