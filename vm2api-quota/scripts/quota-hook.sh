#!/usr/bin/env bash
# quota-hook.sh — UserPromptSubmit hook that intercepts "/quota" and runs the
# quota script locally, printing the report to the terminal (stderr) and
# blocking the prompt so it NEVER reaches the model.
#
# Two interception paths (whichever the host applies first):
#   1. the raw typed text "/quota" or "/vm2api-quota:quota"
#   2. the expanded form of commands/quota.md, whose body is the marker
#      "<!-- vm2api-quota:local [args] -->" (no script execution there)
# Non-matching prompts exit 0 silently and flow through as usual.
#
# Exit codes:
#   0 — prompt not for us, let it pass untouched
#   2 — quota report printed, block the prompt (model never sees anything)

set -u

read_json_field() { # $1 = field name; reads stdin JSON
  if command -v jq >/dev/null 2>&1; then
    jq -r ".$1 // empty" 2>/dev/null || true
  elif command -v python3 >/dev/null 2>&1; then
    python3 -c "
import json,sys
try:
    v=json.load(sys.stdin).get('$1')
    print(v if isinstance(v,str) else '')
except Exception:
    pass
" 2>/dev/null || true
  fi
}

INPUT="$(cat)"
PROMPT="$(printf '%s' "$INPUT" | read_json_field prompt)"
# trim leading whitespace
PROMPT="${PROMPT#"${PROMPT%%[![:space:]]*}"}"

ARG=""
case "$PROMPT" in
  "/quota"|"/quota "*)
    ARG="${PROMPT#/quota}" ;;
  "/vm2api-quota:quota"|"/vm2api-quota:quota "*)
    ARG="${PROMPT#/vm2api-quota:quota}" ;;
  *vm2api-quota:local*)
    # expanded command marker: "<!-- vm2api-quota:local [args] -->"
    ARG="$(printf '%s\n' "$PROMPT" | grep -m1 -o 'vm2api-quota:local[^>]*' | sed 's/^vm2api-quota:local[[:space:]]*//' || true)" ;;
  *)
    exit 0 ;;
esac
ARG="${ARG#"${ARG%%[![:space:]]*}"}"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
bash "$SCRIPT_DIR/quota.sh" $ARG 1>&2
exit 2
