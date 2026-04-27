#!/usr/bin/env python3
"""
typeset_math.py — convert backtick spans in paper.md to LaTeX math.

The paper writes math identifiers and short equations in markdown backticks
(`Q(O, S) = R(A) / 2^I`, `\\sigma_p`, `\\hbar`, etc.) so the source file is
readable in any markdown viewer. For PDF compilation those backtick spans
need to become real LaTeX math; otherwise pandoc renders them as monospace
code, which is wrong for a physics paper.

This script:
  1. Reads paper.md (path passed as argv[1] or default sibling file).
  2. Walks every backtick span.
  3. Classifies each span as "code" (file paths, .swift, known Swift
     identifiers) or "math" (everything else).
  4. For math spans, translates unicode glyphs (Δ σ χ ρ ℏ ≥ ≪ → ⋅ ∈ …) to
     LaTeX commands and replaces the surrounding backticks with `$...$`.
  5. Writes the result to argv[2] or `paper-typeset.md` next to the input.

Usage:
    python3 typeset_math.py [input.md] [output.md]

The script is path-independent: if no arguments are given it operates on
files in the same directory as itself.
"""

import re
import sys
from pathlib import Path


# ---------------------------------------------------------------------------
# Classification: spans we keep as monospace code (Swift identifiers, paths).
# ---------------------------------------------------------------------------

KEEP_AS_CODE = {
    "Double",
    "Int",
    "JeffJS",
    "maxBits = 48",
    "field_size = 32",
}


def is_code_span(content: str) -> bool:
    """True if the span should remain as inline code (NOT math)."""
    if content in KEEP_AS_CODE:
        return True
    if ".swift" in content:
        return True
    if content.startswith("/Users/") or content.startswith("/tmp/"):
        return True
    if "://" in content:
        return True
    return False


# ---------------------------------------------------------------------------
# Unicode → LaTeX translations applied INSIDE math spans only.
# ---------------------------------------------------------------------------

UNICODE_TO_LATEX = {
    "ℏ": r"\hbar",
    "ℓ": r"\ell",
    "√": r"\sqrt",
    "σ": r"\sigma",
    "χ": r"\chi",
    "ρ": r"\rho",
    "Δ": r"\Delta",
    "γ": r"\gamma",
    "κ": r"\kappa",
    "μ": r"\mu",
    "·": r"\cdot",
    "→": r"\to",
    "≤": r"\le",
    "≥": r"\ge",
    "≈": r"\approx",
    "≡": r"\equiv",
    "−": "-",
    "∞": r"\infty",
    "≫": r"\gg",
    "≪": r"\ll",
    "∈": r"\in",
    "∉": r"\notin",
    "∀": r"\forall",
    "∃": r"\exists",
    "∑": r"\sum",
    "∏": r"\prod",
    "²": "^2",
    "³": "^3",
    "⁵": "^5",
    "⁸": "^8",
    "⁰": "^0",
    "⁴": "^4",
    "⁶": "^6",
    "⁷": "^7",
    "⁹": "^9",
    # Combining macron (used in n̄ for "n-bar"). Drop it; the surrounding
    # letter will need to be hand-typed as `\bar{n}` if it really needs to
    # be a bar — in our paper it's only used for cavity photon number,
    # which we can leave as plain `n`.
    "̄": "",
}


# Math function names that need a backslash prefix in LaTeX so they render
# upright instead of italic. Order matters: longer names must come first
# so the regex doesn't shadow them with a shorter prefix.
LATEX_FUNCTIONS = ["log_2", "log", "ln", "exp", "min", "max", "sin", "cos", "sqrt"]
LATEX_FUNCTION_REPLACEMENT = {
    "log_2": r"\log_2",
    "log":   r"\log",
    "ln":    r"\ln",
    "exp":   r"\exp",
    "min":   r"\min",
    "max":   r"\max",
    "sin":   r"\sin",
    "cos":   r"\cos",
    "sqrt":  r"\sqrt",
}

# Sub/super-script patterns that should render as upright multi-character
# tokens: X_min → X_{\min}, X^max → X^{\max}, X_post → X_{\text{post}}, etc.
# Without this, LaTeX renders X_min as the product X · m · i · n in italic
# math, which is wrong.
SUBSCRIPT_PATTERNS = {
    r"_min":  r"_{\min}",
    r"_max":  r"_{\max}",
    r"_post": r"_{\text{post}}",
    r"_prior": r"_{\text{prior}}",
    r"_back": r"_{\text{back}}",
    r"_eff":  r"_{\text{eff}}",
    r"_rate": r"_{\text{rate}}",
    r"^min":  r"^{\min}",
    r"^max":  r"^{\max}",
    r"^post": r"^{\text{post}}",
    r"^prior": r"^{\text{prior}}",
}


def to_math(content: str) -> str:
    """Translate a math-span string to LaTeX-compatible math source."""
    result = content

    # 1. Translate unicode glyphs. For backslash commands, append a trailing
    #    space ONLY when the next character is a letter (which would glue:
    #    \Delta + x → \Deltax, undefined). For non-letter neighbours
    #    (underscores, operators, digits, end-of-string) leave it tight so
    #    subscripts and operators bind: \sigma_p, not \sigma _p.
    for u, latex in UNICODE_TO_LATEX.items():
        if latex.startswith("\\"):
            def repl(m, latex=latex):
                next_char = m.group(1)
                if next_char and next_char.isalpha():
                    return latex + " " + next_char
                return latex + (next_char or "")
            result = re.sub(re.escape(u) + "(.)", repl, result)
            # Catch trailing occurrences (unicode at end of span).
            result = result.replace(u, latex)
        else:
            result = result.replace(u, latex)

    # 2. Convert multi-character sub/super-scripts (_min, ^max, _post, …)
    #    to braced LaTeX form so they render as upright text instead of
    #    italicized letter-products. MUST run before the function-name
    #    rule below, otherwise `min` gets replaced with `\min` first and
    #    the `_min`/`^min` patterns no longer match.
    for pat in sorted(SUBSCRIPT_PATTERNS.keys(), key=len, reverse=True):
        replacement = SUBSCRIPT_PATTERNS[pat]
        result = re.sub(
            rf"{re.escape(pat)}(?![\w])",
            lambda _m, r=replacement: r,
            result,
        )

    # 3. Add backslashes for log_2, min, max, etc., but only as whole tokens
    #    (not preceded by backslash or word char, not followed by word char).
    #    Prevents `max` inside `maxBits` from being mangled to `\maxBits`.
    for fn in LATEX_FUNCTIONS:
        replacement = LATEX_FUNCTION_REPLACEMENT[fn]
        result = re.sub(
            rf"(?<![\\\w]){re.escape(fn)}(?![\w])",
            lambda _m, r=replacement: r,
            result,
        )

    # 4. Convert sqrt(...) to \sqrt{...}. LaTeX's \sqrt takes a braced
    #    argument, not a parenthesized one. Same for cbrt if it ever
    #    appears. Simple one-level matcher.
    result = re.sub(r"\\sqrt\(([^()]*)\)", r"\\sqrt{\1}", result)

    return result


def convert(text: str) -> str:
    pattern = re.compile(r"`([^`\n]+?)`")

    def repl(m):
        content = m.group(1)
        if is_code_span(content):
            return f"`{content}`"
        return f"${to_math(content)}$"

    return pattern.sub(repl, text)


def main():
    here = Path(__file__).resolve().parent
    default_in  = here / "paper.md"
    default_out = here / "paper-typeset.md"

    inp  = Path(sys.argv[1]) if len(sys.argv) > 1 else default_in
    outp = Path(sys.argv[2]) if len(sys.argv) > 2 else default_out

    src = inp.read_text(encoding="utf-8")
    out = convert(src)
    outp.write_text(out, encoding="utf-8")
    print(f"Wrote {outp} ({len(out)} chars, {out.count('$') // 2} math spans)")


if __name__ == "__main__":
    main()
