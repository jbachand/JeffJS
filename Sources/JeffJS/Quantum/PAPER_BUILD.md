# Building the whitepaper PDFs

There are two whitepapers in this directory:

- `paper.md` → `paper.pdf` — long-form whitepaper (~37 pages)
- `paper-engineer.md` → `paper-engineer.pdf` — engineer's edition (~5 pages)

Both are built by the same small pipeline that lives entirely in this directory.

## One-shot

```sh
./build_paper.sh
```

That writes both `paper.pdf` and `paper-engineer.pdf` next to their sources.
First run downloads the LaTeX packages tectonic needs (~50 MB, cached
afterwards); subsequent runs are ~3 seconds total for both documents.

## Requirements

| Tool | Install | Why |
|---|---|---|
| `python3` | preinstalled on macOS | runs the math preprocessor |
| `pandoc` | `brew install pandoc` | markdown → LaTeX |
| `tectonic` | `brew install tectonic` | self-contained modern LaTeX engine |
| `poppler` | `brew install poppler` (optional) | enables `pdfinfo` for the page-count summary |

Total disk: ~150 MB. Tectonic is the lightweight half — it auto-downloads
LaTeX packages on first use and caches them in `~/Library/Caches/Tectonic/`.

## What the pipeline does

1. **`typeset_math.py`** walks every backtick span in `paper.md` and
   classifies it as either *code* (Swift identifiers, file paths,
   `Double`, etc.) or *math* (everything else). Math spans get their
   unicode glyphs (Δ σ χ ρ ℏ ≥ ≪ → ⋅ ∈ …) translated to LaTeX commands,
   then wrapped in `$...$` so pandoc treats them as inline math instead of
   monospace code. The output goes to `/tmp/paper-typeset.md`.

2. **`pandoc + tectonic`** converts that intermediate to a standalone
   LaTeX document and renders it to `paper.pdf`. The flags set 11pt
   font, 1-inch margins, 1.15 line spacing, navy hyperlinks, and a
   linked table of contents.

The intermediate `/tmp/paper-typeset.md` is removed at the end of the
build. If you want to inspect it, run `python3 typeset_math.py` directly.

## Why we need a math preprocessor at all

The paper writes math in markdown backticks
(`` `Q = R / 2^I` ``, `` `\sigma_p` ``, etc.) so the source file stays
readable in any plain markdown viewer — GitHub, an editor preview, etc.
Pandoc renders backtick content as monospace code by default, which is
wrong for a physics paper. Rewriting the source to use `$...$` math
delimiters everywhere would make the markdown ugly to read directly. The
preprocessor lets the source stay clean and the PDF stay typeset.

## Editing the paper

Edit `paper.md`. Re-run `./build_paper.sh`. That's the loop.

If you add new unicode math glyphs that aren't in
`typeset_math.py`'s `UNICODE_TO_LATEX` table, the build will warn (or
fail) — add the new glyph to the table and re-run.

If you reference a Swift identifier, file path, or other code token that
should NOT become math, either add it to `KEEP_AS_CODE` in the
preprocessor or arrange that it ends in `.swift` or contains `/` so the
existing heuristics catch it.

## Files in this directory related to the whitepapers

| File | Purpose |
|---|---|
| `paper.md` | Long-form whitepaper source. |
| `paper.pdf` | Long-form build output. Don't edit by hand; re-run the script. |
| `paper-engineer.md` | Engineer's edition source — short, software-first. |
| `paper-engineer.pdf` | Engineer's edition build output. |
| `typeset_math.py` | Backtick → LaTeX math preprocessor. |
| `build_paper.sh` | Pipeline wrapper: preprocessor + pandoc + tectonic, runs both documents. |
| `PAPER_BUILD.md` | This file. |
