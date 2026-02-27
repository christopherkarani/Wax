#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
OUTPUT_DIR="$PROJECT_DIR/docs/docc-html"

echo "Generating Wax documentation..."

cd "$PROJECT_DIR"

rm -rf "$OUTPUT_DIR"

swift package generate-documentation \
  --target Wax \
  --transform-for-static-hosting \
  --hosting-base-path Wax \
  --output-path "$OUTPUT_DIR"

echo "Docs generated at $OUTPUT_DIR/"
