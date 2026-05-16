#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
OUTPUT_DIR="$PROJECT_DIR/docs/docc-html"
TMP_OUTPUT_DIR="$(mktemp -d "$PROJECT_DIR/.build/docc-html.XXXXXX")"

cleanup() {
  rm -rf "$TMP_OUTPUT_DIR"
}
trap cleanup EXIT

echo "Generating Wax documentation..."

cd "$PROJECT_DIR"

swift package generate-documentation \
  --target Wax \
  --transform-for-static-hosting \
  --hosting-base-path Wax \
  --output-path "$TMP_OUTPUT_DIR"

rm -rf "$OUTPUT_DIR"
mkdir -p "$(dirname "$OUTPUT_DIR")"
mv "$TMP_OUTPUT_DIR" "$OUTPUT_DIR"
trap - EXIT

echo "Docs generated at $OUTPUT_DIR/"
