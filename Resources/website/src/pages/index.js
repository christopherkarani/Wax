import React, { useEffect, useRef, useState } from "react";
import Layout from "@theme/Layout";
import CodeBlock from "@theme/CodeBlock";
import Link from "@docusaurus/Link";

const features = [
  { title: "Fast",          metric: "0.84ms",  desc: "Vector search @ 10K docs on Metal GPU" },
  { title: "Durable",       metric: "Kill-9",  desc: "Power-loss safe. WAL-protected writes." },
  { title: "Deterministic", metric: "100%",    desc: "Same query = same context, every time" },
  { title: "Portable",      metric: "1 file",  desc: "One .wax file — move it, back it up, ship it" },
  { title: "Private",       metric: "0 calls", desc: "100% on-device. Zero network dependency." },
];

const comparison = [
  { feature: "Single file",        wax: true, chroma: false,     coredata: false,     pinecone: false },
  { feature: "Works offline",      wax: true, chroma: "partial", coredata: true,      pinecone: false },
  { feature: "Crash-safe",         wax: true, chroma: false,     coredata: "partial", pinecone: "n/a" },
  { feature: "GPU vector search",  wax: true, chroma: false,     coredata: false,     pinecone: false },
  { feature: "No server required", wax: true, chroma: true,      coredata: true,      pinecone: false },
  { feature: "Swift-native",       wax: true, chroma: false,     coredata: true,      pinecone: false },
  { feature: "Deterministic RAG",  wax: true, chroma: false,     coredata: false,     pinecone: false },
];

const perfBars = [
  { label: "Wax Metal (warm)", value: 0.84, max: 150, unit: "ms", isWax: true  },
  { label: "Wax Metal (cold)", value: 9.2,  max: 150, unit: "ms", isWax: true  },
  { label: "Wax CPU",          value: 105,  max: 150, unit: "ms", isWax: true  },
  { label: "SQLite FTS5",      value: 150,  max: 150, unit: "ms", isWax: false },
];

function CellValue({ val }) {
  if (val === true)      return <span className="check-mark">✓</span>;
  if (val === false)     return <span className="cross-mark">✕</span>;
  if (val === "partial") return <span className="partial-txt">partial</span>;
  return <span className="partial-txt">N/A</span>;
}

function PerfSection() {
  const [animated, setAnimated] = useState(false);
  const ref = useRef(null);

  useEffect(() => {
    const el = ref.current;
    if (!el || typeof IntersectionObserver === "undefined") {
      setAnimated(true);
      return;
    }
    const observer = new IntersectionObserver(
      ([entry]) => { if (entry.isIntersecting) setAnimated(true); },
      { threshold: 0.2 }
    );
    observer.observe(el);
    return () => observer.disconnect();
  }, []);

  return (
    <section className="perf-section" ref={ref}>
      <span className="section-eyebrow">Benchmarks</span>
      <h2 className="section-heading">Vector Search Latency</h2>
      <p className="section-subheading">10,000 × 384-dim documents on Apple Silicon</p>

      {perfBars.map((bar, i) => (
        <div className="perf-bar-container" key={bar.label}>
          <div className="perf-bar-label">
            <span className={`perf-label-name${bar.isWax ? " is-wax" : ""}`}>
              {bar.label}
            </span>
            <span className="perf-label-value">{bar.value}{bar.unit}</span>
          </div>
          <div className="perf-bar-track">
            <div
              className={`perf-bar-fill${bar.isWax ? " is-wax" : ""}`}
              style={{
                width: animated ? `${(bar.value / bar.max) * 100}%` : "0%",
                transitionDelay: animated ? `${i * 0.13}s` : "0s",
              }}
            />
          </div>
        </div>
      ))}

      <div className="perf-stats-row">
        <div>
          <div className="perf-stat-value">17ms</div>
          <div className="perf-stat-label">Cold Open to First Query</div>
        </div>
        <div>
          <div className="perf-stat-value">105ms</div>
          <div className="perf-stat-label">Hybrid Search @ 10K docs</div>
        </div>
      </div>
    </section>
  );
}

const demoCode = `import Wax

// Hybrid search with on-device embeddings (MiniLM, 384-dim)
let brain = try await MemoryOrchestrator.openMiniLM(
    at: URL(fileURLWithPath: "brain.wax")
)

// Remember something
try await brain.remember(
    "User prefers dark mode and gets headaches from bright screens",
    metadata: ["source": "onboarding"]
)

// Recall with RAG
let context = try await brain.recall(query: "user preferences")`;

export default function Home() {
  return (
    <Layout description="On-device RAG for Swift. One file. Zero servers.">

      {/* ── Hero ── */}
      <section className="hero-section">
        <div className="hero-eyebrow">On-device RAG for Swift</div>

        <h1 className="hero-title">Wax</h1>

        <div className="hero-rule" />

        <p className="hero-subtitle">
          Documents, embeddings, BM25 and HNSW indexes in a single file.
          No Docker. No network calls. No cloud dependency.
        </p>

        <div className="hero-buttons">
          <Link className="btn-primary" to="/docs/intro">
            Get Started
          </Link>
          <Link className="btn-ghost" href="https://github.com/christopherkarani/Wax">
            GitHub →
          </Link>
        </div>

        {/* Code demo */}
        <div className="code-demo">
          <div className="code-demo-bar">
            <div className="code-demo-dot" style={{ background: "#ff5f57" }} />
            <div className="code-demo-dot" style={{ background: "#febc2e" }} />
            <div className="code-demo-dot" style={{ background: "#28c840" }} />
            <span className="code-demo-filename">brain.swift</span>
          </div>
          <CodeBlock language="swift">{demoCode}</CodeBlock>
        </div>
      </section>

      {/* ── Stats strip ── */}
      <section className="stats-section">
        <div className="stats-strip">
          {features.map((f) => (
            <div className="stat-item" key={f.title}>
              <div className="stat-label">{f.title}</div>
              <div className="stat-value">{f.metric}</div>
              <div className="stat-desc">{f.desc}</div>
            </div>
          ))}
        </div>
      </section>

      {/* ── Performance ── */}
      <PerfSection />

      {/* ── Comparison ── */}
      <section className="comparison-section">
        <span className="section-eyebrow">How it compares</span>
        <h2 className="section-heading">Comparison</h2>
        <p className="section-subheading">Wax vs. the alternatives for iOS/macOS.</p>

        <table>
          <thead>
            <tr>
              <th style={{ textAlign: "left" }}>Feature</th>
              <th className="wax-col" style={{ textAlign: "center" }}>Wax</th>
              <th style={{ textAlign: "center" }}>Chroma</th>
              <th style={{ textAlign: "center" }}>Core Data + FAISS</th>
              <th style={{ textAlign: "center" }}>Pinecone</th>
            </tr>
          </thead>
          <tbody>
            {comparison.map((row) => (
              <tr key={row.feature}>
                <td>{row.feature}</td>
                <td className="wax-col" style={{ textAlign: "center" }}>
                  <CellValue val={row.wax} />
                </td>
                <td style={{ textAlign: "center" }}><CellValue val={row.chroma} /></td>
                <td style={{ textAlign: "center" }}><CellValue val={row.coredata} /></td>
                <td style={{ textAlign: "center" }}><CellValue val={row.pinecone} /></td>
              </tr>
            ))}
          </tbody>
        </table>
      </section>

      <div style={{ height: "5rem" }} />
    </Layout>
  );
}
