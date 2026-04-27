#!/usr/bin/env bash
#
# build_paper.sh — compile both whitepaper PDFs.
#
# Builds two documents:
#   1. paper.pdf          — long-form whitepaper (paper.md)
#   2. paper-engineer.pdf — short engineer's edition (paper-engineer.md)
#
# Pipeline (per document):
#   1. typeset_math.py converts backtick spans to LaTeX math
#      (writing the intermediate to /tmp/<name>-typeset.md).
#   2. pandoc converts the typeset markdown into a standalone LaTeX file
#      and hands it to tectonic for rendering.
#   3. The final PDF is written next to the source markdown.
#
# Requirements:
#   - python3 (any 3.x)
#   - pandoc        (brew install pandoc)
#   - tectonic      (brew install tectonic)  modern self-contained LaTeX
#   - poppler       (brew install poppler)   only needed for `pdfinfo` checks
#
# Usage:
#   ./build_paper.sh

set -euo pipefail

# Resolve script directory so the build works from any cwd.
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"

# Sanity-check tooling.
for tool in python3 pandoc tectonic; do
    if ! command -v "$tool" >/dev/null 2>&1; then
        echo "error: $tool not found in PATH" >&2
        echo "       install: brew install pandoc tectonic" >&2
        exit 1
    fi
done

# build_one <source.md> <output.pdf> <title>
build_one() {
    local src="$1"
    local out="$2"
    local title="$3"
    local base
    base=$(basename "$src" .md)
    local typeset_md="/tmp/${base}-typeset.md"

    echo "  [preprocess] $base"
    python3 "$SCRIPT_DIR/typeset_math.py" "$src" "$typeset_md"

    local pre_mtime
    pre_mtime=$(stat -f %m "$out" 2>/dev/null || echo 0)

    echo "  [compile]    $base → $(basename "$out")"
    set +e
    pandoc "$typeset_md" \
        -o "$out" \
        --pdf-engine=tectonic \
        --standalone \
        --variable=fontsize:11pt \
        --variable=geometry:margin=1in \
        --variable=linestretch:1.15 \
        --variable=colorlinks:true \
        --variable=linkcolor:NavyBlue \
        --variable=urlcolor:NavyBlue \
        --metadata=title:"$title" \
        --metadata=author:"Jeff Bachand" \
        --metadata=date:"April 2026" \
        --toc \
        2>&1 | grep -vE "^warning: .*hbox" || true
    local pandoc_status=${PIPESTATUS[0]}
    set -e

    local post_mtime
    post_mtime=$(stat -f %m "$out" 2>/dev/null || echo 0)
    if [ "$pandoc_status" -ne 0 ] || [ "$post_mtime" = "$pre_mtime" ]; then
        echo "error: pandoc/tectonic failed (status=$pandoc_status); $(basename "$out") was not regenerated" >&2
        exit 1
    fi

    rm -f "$typeset_md"

    local size
    size=$(ls -lh "$out" | awk '{print $5}')
    if command -v pdfinfo >/dev/null 2>&1; then
        local pages
        pages=$(pdfinfo "$out" | awk '/^Pages:/ {print $2}')
        echo "  [done]       $(basename "$out") ($size, $pages pages)"
    else
        echo "  [done]       $(basename "$out") ($size)"
    fi
}

echo "[1/2] Building long-form whitepaper..."
build_one \
    "$SCRIPT_DIR/paper.md" \
    "$SCRIPT_DIR/paper.pdf" \
    "JeffJS Quantum: An Information-Theoretic Encoding Framework"

echo "[2/2] Building engineer's edition..."
build_one \
    "$SCRIPT_DIR/paper-engineer.md" \
    "$SCRIPT_DIR/paper-engineer.pdf" \
    "JeffJS Quantum (Engineer's Edition)"

echo "Done."
