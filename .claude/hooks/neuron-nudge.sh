#!/bin/bash
# Claude Neuron Architecture — PostToolUse nudge (never blocks).
# After an Edit/Write/MultiEdit of a source or interface file, point Claude at the
# nearest area CLAUDE.md ("neuron") above the file and ask it to update that doc in
# the same change when the edit touched something the doc describes. If the only
# CLAUDE.md above the file is the repo root's, suggest creating an area doc.
# Input: the hook's JSON on stdin (tool_input.file_path). Output: PostToolUse JSON
# with additionalContext. Always exits 0.
set -u
input=$(cat)
file=$(printf '%s' "$input" | python3 -c '
import json, sys
try:
    d = json.load(sys.stdin)
    ti = d.get("tool_input") or {}
    print(ti.get("file_path") or ti.get("notebook_path") or "")
except Exception:
    print("")
' 2>/dev/null)
[ -z "$file" ] && exit 0
case "$file" in
  *.swift|*.metal|*.js|*.mjs|*.html|*.css|*.py|*.sh|*.plist|*.pbxproj|*.json) ;;
  *) exit 0 ;;
esac
case "$file" in
  */CLAUDE.md|*/docs/claude/*|*/.claude/*|*/build/*|*/visual_output/*|*/css_test_output/*) exit 0 ;;
esac
root=$(cd "$(dirname "$0")/../.." && pwd -P)
dir=$(cd "$(dirname "$file")" 2>/dev/null && pwd -P) || exit 0
case "$dir" in "$root"|"$root"/*) ;; *) exit 0 ;; esac
neuron=""
d="$dir"
while [ "$d" != "$root" ] && [ -n "$d" ] && [ "$d" != "/" ]; do
  if [ -f "$d/CLAUDE.md" ]; then neuron="$d/CLAUDE.md"; break; fi
  d=$(dirname "$d")
done
rel_file=${file#"$root/"}
if [ -n "$neuron" ]; then
  rel_neuron=${neuron#"$root/"}
  msg="Neuron check: you edited $rel_file. Its area doc is $rel_neuron. If this change touched a file, invariant, gotcha, switch, pattern or dead-code claim that doc describes, update the doc in the same change and bump its 'Last reviewed' line. If it changes something cross-cutting, also update the app repo's docs/claude/ARCHITECTURE.md (and DEAD_CODE / KNOWN_ISSUES / PERFORMANCE rollups when relevant), then rebuild the explorer data with the app repo's Scripts/claude_network/build-claude-data.mjs. Never add a claim you have not verified against the tree."
else
  msg="Neuron check: you edited $rel_file, which has no area CLAUDE.md above it (only the root map). If this folder is an important area, consider creating <folder>/CLAUDE.md with the neuron layout (see the app repo's docs/claude/ARCHITECTURE.md 'How to write a neuron') and listing it in the root CLAUDE.md index. Never add a claim you have not verified against the tree."
fi
printf '%s' "$msg" | python3 -c '
import json, sys
print(json.dumps({"hookSpecificOutput": {"hookEventName": "PostToolUse", "additionalContext": sys.stdin.read()}}))
'
exit 0
