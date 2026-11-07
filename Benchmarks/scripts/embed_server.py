#!/usr/bin/env python3
"""Serve a Hugging Face encoder over local HTTP so wax-bench can embed with it.

This lets Wax and a bare reference retriever share one embedding model, so a
comparison measures the Wax pipeline (chunking, hybrid fusion, ranking) rather
than the model. Run wax-bench with `--embedder http://127.0.0.1:<port>`.

  GET  /info   -> {"model": "...", "dimensions": 768}
  POST /embed  {"texts": ["..."]} -> {"vectors": [[...], ...]}

Pooling matches longmemeval_baselines.py: mean over the attention mask, inputs
truncated to 512 tokens. Vectors are returned unnormalized; Wax normalizes them.
Each distinct text is embedded once per server process.

  python3 -I embed_server.py --model facebook/contriever --port 8765 [--device mps]
"""
import argparse
import hashlib
import json
import sys
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

MAX_TOKENS = 512
BATCH_SIZE = 32
MAX_TEXTS_PER_REQUEST = 4096


class Encoder:
    def __init__(self, model_id: str, device: str) -> None:
        import torch
        from transformers import AutoModel, AutoTokenizer

        self.torch = torch
        self.device = device
        self.tokenizer = AutoTokenizer.from_pretrained(model_id)
        self.model = AutoModel.from_pretrained(model_id).to(device).eval()
        self.model_id = model_id
        self.dimensions = int(self.model.config.hidden_size)
        self.cache: dict[str, list[float]] = {}
        self.lock = threading.Lock()

    def _encode(self, texts: list[str]) -> list[list[float]]:
        torch = self.torch
        vectors: list[list[float]] = []
        with torch.no_grad():
            for start in range(0, len(texts), BATCH_SIZE):
                batch = texts[start:start + BATCH_SIZE]
                inputs = self.tokenizer(
                    batch, padding=True, truncation=True, max_length=MAX_TOKENS, return_tensors="pt"
                )
                inputs = {key: value.to(self.device) for key, value in inputs.items()}
                hidden = self.model(**inputs)[0]
                mask = inputs["attention_mask"]
                hidden = hidden.masked_fill(~mask[..., None].bool(), 0.0)
                pooled = hidden.sum(dim=1) / mask.sum(dim=1)[..., None]
                vectors.extend(pooled.float().cpu().tolist())
        return vectors

    def embed(self, texts: list[str]) -> list[list[float]]:
        keys = [hashlib.sha1(text.encode("utf-8")).hexdigest() for text in texts]
        with self.lock:
            missing = sorted({key: text for key, text in zip(keys, texts) if key not in self.cache}.items())
            if missing:
                encoded = self._encode([text for _, text in missing])
                for (key, _), vector in zip(missing, encoded):
                    self.cache[key] = vector
            return [self.cache[key] for key in keys]


def make_handler(encoder: Encoder) -> type[BaseHTTPRequestHandler]:
    class Handler(BaseHTTPRequestHandler):
        def _reply(self, status: int, payload: dict) -> None:
            body = json.dumps(payload).encode("utf-8")
            self.send_response(status)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)

        def do_GET(self) -> None:
            if self.path == "/info":
                self._reply(200, {"model": encoder.model_id, "dimensions": encoder.dimensions})
            else:
                self._reply(404, {"error": "not found"})

        def do_POST(self) -> None:
            if self.path != "/embed":
                self._reply(404, {"error": "not found"})
                return
            try:
                length = int(self.headers.get("Content-Length", "0"))
                texts = json.loads(self.rfile.read(length))["texts"]
                if not isinstance(texts, list) or not all(isinstance(text, str) for text in texts):
                    raise ValueError("texts must be a list of strings")
                if len(texts) > MAX_TEXTS_PER_REQUEST:
                    raise ValueError(f"at most {MAX_TEXTS_PER_REQUEST} texts per request")
            except (ValueError, KeyError, json.JSONDecodeError) as error:
                self._reply(400, {"error": str(error)})
                return
            self._reply(200, {"vectors": encoder.embed(texts)})

        def log_message(self, format: str, *args: object) -> None:
            return

    return Handler


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--model", default="facebook/contriever")
    parser.add_argument("--port", type=int, default=8765)
    parser.add_argument("--device", default="mps")
    args = parser.parse_args()

    encoder = Encoder(args.model, args.device)
    server = ThreadingHTTPServer(("127.0.0.1", args.port), make_handler(encoder))
    print(f"serving {args.model} ({encoder.dimensions} dims) on 127.0.0.1:{args.port}", file=sys.stderr, flush=True)
    server.serve_forever()


if __name__ == "__main__":
    main()
