#!/usr/bin/env bash
# quota.sh — read-only usage/quota reporter for a vm2api gateway.
#
# Fetches:
#   1. Current account 5h/7d quota : GET {base}/v1/usage?unit=percent_used   (API key)
#   2. Per-account pool quota      : GET {base}/api/panel/vms                (panel token)
#      -> data.items[] with utilization_5h/7d (ratio 0-1), reset_5h/7d,
#         status_5h/7d and estimate_5h/7d USD figures
#   3. Billing summary             : GET {base}/api/panel/usage              (panel token)
#      -> data.billing.{today,window_5h,total} cost/request figures
#
# Credential resolution (highest priority first; nothing is hardcoded):
#   base URL    : config file -> CLAUDE_PLUGIN_OPTION_BASE_URL (plugin userConfig)
#                 -> VM2API_BASE_URL -> ANTHROPIC_BASE_URL -> ~/.claude/settings.json
#                 -> none: the report errors out with a hint (no default URL)
#   /v1 api key : config file api_key -> CLAUDE_PLUGIN_OPTION_MASTER_KEY (plugin
#                 userConfig) -> VM2API_API_KEY -> ANTHROPIC_AUTH_TOKEN ->
#                 ANTHROPIC_API_KEY -> settings.json
#   panel token : CLAUDE_PLUGIN_OPTION_PANEL_TOKEN (plugin userConfig) ->
#                 VM2API_PANEL_TOKEN -> config file panel_token -> master key
#                 (config file or VM2API_API_KEY).
#                 Any /api/panel/* credential works: the master key or a console
#                 session token issued by POST /api/panel/login.
#                 A plain `sk-vm-` key CANNOT read panel endpoints (403).
#
# Runtime configuration subcommands (persist to ~/.config/vm2api-quota/config.json):
#   quota.sh config                      show effective config (masked)
#   quota.sh set    base-url <URL>       store gateway URL
#   quota.sh set    api-key <KEY>        store master/api key (alias: master-key)
#   quota.sh set    panel-token <TOKEN>  store panel credential
#   quota.sh unset  base-url|api-key|panel-token
#
# This script performs only GET requests plus local config-file writes via the
# subcommands above; it never mutates anything on the gateway.

set -u

MODE="human"
case "${1:-}" in
  set|unset|config|setup-bare)
    ACTION="$1"; CKEY="${2:-}"; CVALUE="${3:-}" ;;
  *)
    ACTION=""
    for arg in "$@"; do
      case "$arg" in
        --json) MODE="json" ;;
        *) ;; # ignore unknown args (e.g. unparsed $ARGUMENTS)
      esac
    done
    ;;
esac

SETTINGS_CANDIDATES=(
  "${HOME}/.claude/settings.json"
  "${HOME}/.zcode/settings.json"
)
PANEL_TOKEN_FILE="${HOME}/.config/vm2api/panel-token"
# primary config file (also written by the JS hooks module), plus legacy path
CONFIG_CANDIDATES=(
  "${HOME}/.claude/vm2api-quota-config.json"
  "${HOME}/.config/vm2api-quota/config.json"
)
CONFIG_FILE="${HOME}/.claude/vm2api-quota-config.json"

# ---------- local config file (runtime /quota set|unset|config) ----------

config_get() { # $1 key; prints value or empty (checks all candidate paths)
  local file val
  for file in "${CONFIG_CANDIDATES[@]}"; do
    [ -r "$file" ] || continue
    if command -v jq >/dev/null 2>&1; then
      val="$(jq -r --arg k "$1" '.[$k] // empty' "$file" 2>/dev/null)" || val=""
    elif command -v python3 >/dev/null 2>&1; then
      val="$(python3 -c '
import json,sys
try:
    v=json.load(open(sys.argv[1])).get(sys.argv[2],"")
    print(v if isinstance(v,str) else "")
except Exception:
    pass
' "$file" "$1" 2>/dev/null || true)"
    else
      val=""
    fi
    [ -n "$val" ] && { printf '%s' "$val"; return 0; }
  done
  return 0
}

config_write() { # $1 key, $2 value
  local dir tmp rc=0
  dir="$(dirname "$CONFIG_FILE")"
  mkdir -p "$dir" 2>/dev/null && chmod 700 "$dir" 2>/dev/null || true
  tmp="${CONFIG_FILE}.tmp.$$"
  if command -v jq >/dev/null 2>&1; then
    if ! jq --arg k "$1" --arg v "$2" '. + {($k): $v}' "$CONFIG_FILE" >"$tmp" 2>/dev/null; then
      jq -n --arg k "$1" --arg v "$2" '{($k): $v}' >"$tmp" 2>/dev/null || rc=1
    fi
  elif command -v python3 >/dev/null 2>&1; then
    python3 -c '
import json,sys
path,key,val=sys.argv[1],sys.argv[2],sys.argv[3]
try: d=json.load(open(path))
except Exception: d={}
d[key]=val
json.dump(d,open(path,"w"))
' "$CONFIG_FILE" "$1" "$2" 2>/dev/null || rc=1
  else
    echo "ERROR: writing config needs jq or python3"
    return 1
  fi
  [ "$rc" -eq 0 ] && mv "$tmp" "$CONFIG_FILE" && chmod 600 "$CONFIG_FILE"
  return "$rc"
}

config_delete() { # $1 key
  [ -r "$CONFIG_FILE" ] || return 0
  local tmp="${CONFIG_FILE}.tmp.$$"
  if command -v jq >/dev/null 2>&1; then
    jq --arg k "$1" 'del(.[$k])' "$CONFIG_FILE" >"$tmp" 2>/dev/null && mv "$tmp" "$CONFIG_FILE"
  elif command -v python3 >/dev/null 2>&1; then
    python3 -c '
import json,sys
path,key=sys.argv[1],sys.argv[2]
try: d=json.load(open(path))
except Exception: d={}
d.pop(key,None)
json.dump(d,open(path,"w"))
' "$CONFIG_FILE" "$1" 2>/dev/null || true
  fi
}

mask_val() { # never print full credentials
  local v="$1"
  [ -n "$v" ] || { printf '<not set>'; return; }
  if [ "${#v}" -le 10 ]; then printf '%s…' "$v"; else printf '%s…(%s ch)' "${v:0:10}" "${#v}"; fi
}

# ---------- config resolution ----------

settings_get() { # $1 = jq path (e.g. .env.ANTHROPIC_BASE_URL)
  local path="$1" file val
  for file in "${SETTINGS_CANDIDATES[@]}"; do
    [ -r "$file" ] || continue
    if command -v jq >/dev/null 2>&1; then
      val="$(jq -r "$path // empty" "$file" 2>/dev/null)" || val=""
    elif command -v python3 >/dev/null 2>&1; then
      val="$(python3 -c "
import json
try:
    node=json.load(open('$file'))
    for part in '${path#.}'.split('.'):
        node=node.get(part) if isinstance(node,dict) else None
        if node is None: break
    print(node if isinstance(node,str) else '')
except Exception:
    pass
" 2>/dev/null)" || val=""
    else
      val=""
    fi
    [ -n "$val" ] && { printf '%s' "$val"; return 0; }
  done
  return 1
}

CFG_BASE="$(config_get base_url)"
CFG_KEY="$(config_get api_key)"
CFG_PANEL="$(config_get panel_token)"

BASE_URL="${CFG_BASE:-${CLAUDE_PLUGIN_OPTION_BASE_URL:-${VM2API_BASE_URL:-${ANTHROPIC_BASE_URL:-}}}}"
[ -n "$BASE_URL" ] || BASE_URL="$(settings_get .env.ANTHROPIC_BASE_URL)" || BASE_URL=""
BASE_URL="${BASE_URL%/}"

API_KEY="${CFG_KEY:-${CLAUDE_PLUGIN_OPTION_MASTER_KEY:-${VM2API_API_KEY:-${ANTHROPIC_AUTH_TOKEN:-${ANTHROPIC_API_KEY:-}}}}}"
[ -n "$API_KEY" ] || API_KEY="$(settings_get .env.ANTHROPIC_AUTH_TOKEN)" || API_KEY=""
[ -n "$API_KEY" ] || API_KEY="$(settings_get .env.ANTHROPIC_API_KEY)" || API_KEY=""

PANEL_TOKEN="${CLAUDE_PLUGIN_OPTION_PANEL_TOKEN:-${VM2API_PANEL_TOKEN:-}}"
[ -n "$PANEL_TOKEN" ] || PANEL_TOKEN="${CFG_PANEL:-}"
[ -n "$PANEL_TOKEN" ] || { [ -r "$PANEL_TOKEN_FILE" ] && PANEL_TOKEN="$(tr -d ' \t\n\r' < "$PANEL_TOKEN_FILE")"; }
# VM2API_API_KEY is the gateway's master-key variable; a master key is accepted
# on panel routes too, so it doubles as a panel credential when no dedicated
# panel token is configured. (Do NOT fall back to ANTHROPIC_AUTH_TOKEN here:
# a plain sk-vm- key is rejected by panel routes with 403.)
[ -n "$PANEL_TOKEN" ] || PANEL_TOKEN="${CFG_KEY:-${CLAUDE_PLUGIN_OPTION_MASTER_KEY:-${VM2API_API_KEY:-}}}"

setup_bare() { # $1 = optional --force; writes a PERSONAL command file so the
  # bare /quota works (personal commands are not plugin-namespaced)
  local dir="${HOME}/.claude/commands" file="${HOME}/.claude/commands/quota.md"
  if [ -e "$file" ] && [ "$1" != "--force" ]; then
    echo "already exists: $file (use 'setup-bare --force' to overwrite)"
    return 0
  fi
  if ! mkdir -p "$dir" 2>/dev/null; then
    echo "ERROR: cannot create $dir"
    return 1
  fi
  if ! cat > "$file" <<'MDEOF'
---
description: vm2api quota — intercepted and executed locally by the vm2api-quota hook (zero LLM)
argument-hint: "[--json | config | set <item> <value> | unset <item>]"
disable-model-invocation: true
---

<!-- vm2api-quota:local $ARGUMENTS -->
MDEOF
  then
    echo "ERROR: cannot write $file"
    return 1
  fi
  echo "created: $file"
  echo "reload plugins (or restart the session), then the bare /quota command works"
  echo "remove the file to uninstall it"
}

# ---------- config subcommands (quota.sh set|unset|config|setup-bare) ----------

if [ -n "$ACTION" ]; then
  case "$ACTION" in
    setup-bare)
      setup_bare "$CKEY" ;;
    config)
      echo "=== vm2api-quota config ==="
      echo "config file : $CONFIG_FILE"
      echo "gateway url : ${BASE_URL:-<not set>}   [effective]"
      echo "api key     : $(mask_val "$API_KEY")  [effective]"
      echo "panel token : $(mask_val "$PANEL_TOKEN")  [effective]"
      echo ""
      echo "stored in config file:"
      echo "  base-url    : $(mask_val "$CFG_BASE")"
      echo "  api-key     : $(mask_val "$CFG_KEY")"
      echo "  panel-token : $(mask_val "$CFG_PANEL")"
      echo ""
      echo "plugin userConfig (prompted when the plugin is enabled):"
      echo "  base_url    : $(mask_val "${CLAUDE_PLUGIN_OPTION_BASE_URL:-}")"
      echo "  master_key  : $(mask_val "${CLAUDE_PLUGIN_OPTION_MASTER_KEY:-}")"
      echo "  panel_token : $(mask_val "${CLAUDE_PLUGIN_OPTION_PANEL_TOKEN:-}")"
      echo ""
      echo "priority: config file > plugin userConfig > env (VM2API_*/ANTHROPIC_*) > ~/.claude/settings.json > defaults"
      ;;
    set|unset)
      case "$CKEY" in
        base-url) KEY_F="base_url" ;;
        api-key|master-key) KEY_F="api_key" ;;
        panel-token) KEY_F="panel_token" ;;
        "") echo "usage: /quota set <base-url|api-key|master-key|panel-token> <value>  |  /quota unset <item>  |  /quota config  |  /quota setup-bare [--force]" ;;
        *) echo "unknown config item '$CKEY' (use base-url | api-key | master-key | panel-token)" ;;
      esac
      if [ -n "${KEY_F:-}" ]; then
        if [ "$ACTION" = "set" ]; then
          if [ -z "$CVALUE" ]; then
            echo "usage: /quota set $CKEY <value>"
          elif config_write "$KEY_F" "$CVALUE"; then
            echo "saved $CKEY = $(mask_val "$CVALUE")  -> $CONFIG_FILE"
          else
            echo "ERROR: failed to write $CONFIG_FILE"
          fi
        else
          config_delete "$KEY_F"
          echo "cleared $CKEY from $CONFIG_FILE"
        fi
      fi
      ;;
  esac
  exit 0
fi

# ---------- helpers ----------

fail() { # always exit 0 so the command's !`...` injection does not abort
  if [ "$MODE" = "json" ]; then
    printf '{"ok":false,"error":"%s"}\n' "$1"
  else
    printf '=== vm2api quota query failed ===\nERROR: %s\n' "$1"
  fi
  exit 0
}

http_get() { # $1 url, $2 bearer token (may be empty); sets RESP and CODE
  local url="$1" token="$2" tmp code
  tmp="$(mktemp)"
  if [ -n "$token" ]; then
    code="$(curl -sS --noproxy '*' -m 15 -o "$tmp" -w '%{http_code}' \
      -H "Authorization: Bearer $token" "$url" 2>/dev/null)" || code="000"
  else
    code="$(curl -sS --noproxy '*' -m 15 -o "$tmp" -w '%{http_code}' "$url" 2>/dev/null)" || code="000"
  fi
  RESP="$(cat "$tmp" 2>/dev/null)"
  rm -f "$tmp"
  CODE="$code"
}

jget() { # $1 = jq expression against RESP; empty on parse failure
  if command -v jq >/dev/null 2>&1; then
    printf '%s' "$RESP" | jq -r "$1 // empty" 2>/dev/null || true
  elif command -v python3 >/dev/null 2>&1; then
    printf '%s' "$RESP" | python3 -c "
import json,sys
def dig(o,path):
    for p in path.split('.'):
        if not isinstance(o,dict) or p not in o: return None
        o=o[p]
    return o
try:
    v=dig(json.load(sys.stdin),'$1')
    if v is not None: print(v)
except Exception:
    pass
" 2>/dev/null || true
  fi
}

fmt_time() { # $1 = epoch seconds; prints local time + countdown
  local epoch="$1" now abs human rel rel_txt
  [ -n "$epoch" ] || { printf 'n/a'; return; }
  now="$(date +%s)"
  abs="${epoch%%.*}"
  if date -r 1 >/dev/null 2>&1; then
    human="$(date -r "$abs" '+%Y-%m-%d %H:%M:%S %Z' 2>/dev/null)" || human="$abs"
  else
    human="$(date -d @"$abs" '+%Y-%m-%d %H:%M:%S %Z' 2>/dev/null)" || human="$abs"
  fi
  rel=$(( abs - now ))
  if [ "$rel" -le 0 ]; then
    rel_txt="window active"
  elif [ "$rel" -ge 3600 ]; then
    rel_txt="in $(( rel / 3600 ))h$(( (rel % 3600) / 60 ))m"
  else
    rel_txt="in $(( (rel + 59) / 60 ))m"
  fi
  printf '%s (%s)' "$human" "$rel_txt"
}

fmt_usd() { # $1 = number; prints 2-decimal dollars, empty input -> empty
  [ -n "$1" ] || return 0
  printf '$%.2f' "$1" 2>/dev/null || printf '$%s' "$1"
}

bar() { # $1 = percent
  local pct="${1:-0}" filled total=12 i out
  filled=$(( pct * total / 100 ))
  [ "$filled" -gt "$total" ] && filled=$total
  [ "$filled" -lt 0 ] && filled=0
  out="["
  for ((i=0;i<total;i++)); do
    if (( i < filled )); then out+="█"; else out+="·"; fi
  done
  printf '%s]' "$out"
}

status_tag() {
  case "$1" in
    allowed|active)     printf 'OK' ;;
    allowed_warning)    printf 'WARN' ;;
    blocked|rejected)   printf 'BLOCKED' ;;
    throttled)          printf 'THROTTLED' ;;
    *)                  printf '%s' "${1:-UNKNOWN}" ;;
  esac
}

window_line() { # $1 label, $2 percent, $3 status, $4 reset epoch, $5 optional suffix
  printf '%s %s %3s%%  [%s]  resets %s%s\n' "$1" "$(bar "$2")" "$2" "$(status_tag "$3")" "$(fmt_time "$4")" "${5:-}"
}

# ---------- 1. current account quota (/v1/usage) ----------

[ -n "$BASE_URL" ] || fail "No gateway URL configured. Set it via '/quota set base-url <URL>', VM2API_BASE_URL / ANTHROPIC_BASE_URL, or env.ANTHROPIC_BASE_URL in ~/.claude/settings.json"
[ -n "$API_KEY" ] || fail "No API key found. Set VM2API_API_KEY / ANTHROPIC_AUTH_TOKEN, or configure env.ANTHROPIC_AUTH_TOKEN in ~/.claude/settings.json"

# When every pool account is rate-limited the gateway 429s /v1/usage itself;
# the panel endpoints still serve the real numbers, so fall back to the pool.
USAGE_OK=0
USAGE_NOTE=""
http_get "$BASE_URL/v1/usage?unit=percent_used" "$API_KEY"
USAGE_RESP="$RESP"
case "$CODE" in
  200) USAGE_OK=1 ;; # ok
  429)
    if [ -z "$PANEL_TOKEN" ]; then
      fail "Quota exhausted: /v1/usage is rate-limited (429, upstream_rate_limit). Set a panel credential (e.g. the master key via '/quota set api-key') to keep showing pool-based numbers."
    fi
    USAGE_NOTE="(upstream rate-limited 429 - window numbers from the pool)" ;;
  401|403) fail "Gateway auth error (HTTP $CODE): $(printf '%s' "$USAGE_RESP" | head -c 200)" ;;
  000) fail "Request failed: gateway unreachable at $BASE_URL" ;;
  *) fail "Gateway returned HTTP $CODE: $(printf '%s' "$USAGE_RESP" | head -c 200)" ;;
esac

if [ "$USAGE_OK" = "1" ]; then
  case "$USAGE_RESP" in
    *missing_api_key*|*authentication_error*|*forbidden*)
      fail "Gateway returned an auth error: $(printf '%s' "$USAGE_RESP" | head -c 200)" ;;
  esac
  U5="$(jget .five_hour.utilization)"
  U7="$(jget .seven_day.utilization)"
  R5="$(jget .five_hour.resets_at)"
  R7="$(jget .seven_day.resets_at)"
  S5="$(jget .five_hour.status)"
  S7="$(jget .seven_day.status)"
  PLATFORM="$(jget .platform)"
  SOURCE="$(jget .source)"
  [ -n "$U5" ] || [ -n "$U7" ] || fail "Cannot parse response: $(printf '%s' "$USAGE_RESP" | head -c 200)"
fi

# ---------- 2. per-account pool quota (/api/panel/vms) ----------

VMS=""
POOL_NOTE=""
BILL=""
BILL_NOTE=""
if [ -z "$PANEL_TOKEN" ]; then
  POOL_NOTE="skipped: no panel credential. Set VM2API_PANEL_TOKEN (any /api/panel/* credential: console session token from POST /api/panel/login) or VM2API_API_KEY (gateway master key)"
  BILL_NOTE="$POOL_NOTE"
else
  http_get "$BASE_URL/api/panel/vms" "$PANEL_TOKEN"
  if [ "$CODE" = "200" ] && printf '%s' "$RESP" | grep -q '"items"'; then
    VMS="$RESP"
  else
    POOL_NOTE="unavailable (HTTP $CODE from /api/panel/vms)"
  fi
  http_get "$BASE_URL/api/panel/usage" "$PANEL_TOKEN"
  if [ "$CODE" = "200" ] && printf '%s' "$RESP" | grep -q '"billing"'; then
    BILL="$RESP"
  else
    BILL_NOTE="unavailable (HTTP $CODE from /api/panel/usage)"
  fi
fi

# 429 fallback: fill the current-account windows from the first pool account
if [ "$USAGE_OK" != "1" ] && [ -n "$VMS" ]; then
  if command -v jq >/dev/null 2>&1; then
    U5="$(printf '%s' "$VMS" | jq -r '(.data.items[0].utilization_5h // 0) * 100 | round' 2>/dev/null || echo 0)"
    U7="$(printf '%s' "$VMS" | jq -r '(.data.items[0].utilization_7d // 0) * 100 | round' 2>/dev/null || echo 0)"
    R5="$(printf '%s' "$VMS" | jq -r '.data.items[0].reset_5h // empty' 2>/dev/null || true)"
    R7="$(printf '%s' "$VMS" | jq -r '.data.items[0].reset_7d // empty' 2>/dev/null || true)"
    S5="$(printf '%s' "$VMS" | jq -r '.data.items[0].status_5h // "unknown"' 2>/dev/null || echo unknown)"
    S7="$(printf '%s' "$VMS" | jq -r '.data.items[0].status_7d // "unknown"' 2>/dev/null || echo unknown)"
  else
    FALL="$(printf '%s' "$VMS" | python3 -c '
import json,sys
try:
    v=json.load(sys.stdin)["data"]["items"][0]
    print(round((v.get("utilization_5h") or 0)*100), round((v.get("utilization_7d") or 0)*100),
          v.get("reset_5h") or "-", v.get("reset_7d") or "-",
          v.get("status_5h") or "unknown", v.get("status_7d") or "unknown")
except Exception:
    print(0, 0, "-", "-", "unknown", "unknown")
' 2>/dev/null)"
    U5="$(printf '%s\n' "$FALL" | awk '{print $1}')"
    U7="$(printf '%s\n' "$FALL" | awk '{print $2}')"
    R5="$(printf '%s\n' "$FALL" | awk '{print $3}')"; [ "$R5" = "-" ] && R5=""
    R7="$(printf '%s\n' "$FALL" | awk '{print $4}')"; [ "$R7" = "-" ] && R7=""
    S5="$(printf '%s\n' "$FALL" | awk '{print $5}')"
    S7="$(printf '%s\n' "$FALL" | awk '{print $6}')"
  fi
  PLATFORM="gateway"; SOURCE="pool"
fi

pool_rows() { # TSV per line (NO email/uuid: keep identities out of LLM context):
  # id|name|u5%|u7%|reset5|reset7|status5|status7|e5spent/total|e7spent/total
  # jq first; if the jq program fails on an old/exotic jq (silent empty output),
  # fall back to python3 instead of reporting no rows.
  local out=""
  if command -v jq >/dev/null 2>&1; then
    out="$(printf '%s' "$VMS" | jq -r '
      .data.items[]? |
      [.id, (.name // "-"),
       ((.utilization_5h // 0) * 100 | round),
       ((.utilization_7d // 0) * 100 | round),
       (.reset_5h // ""), (.reset_7d // ""),
       (.status_5h // "unknown"), (.status_7d // "unknown"),
       ((.estimate_5h.spent_usd // null) as $s | (.estimate_5h.total_usd // null) as $t |
        (if $s == null or $t == null then "" else (($s * 100 | round) / 100 | tostring) + "/" + (($t * 100 | round) / 100 | tostring) end)),
       ((.estimate_7d.spent_usd // null) as $s | (.estimate_7d.total_usd // null) as $t |
        (if $s == null or $t == null then "" else (($s * 100 | round) / 100 | tostring) + "/" + (($t * 100 | round) / 100 | tostring) end))] | @tsv' 2>/dev/null || true)"
  fi
  if [ -z "$out" ] && command -v python3 >/dev/null 2>&1; then
    out="$(printf '%s' "$VMS" | python3 -c '
import json,sys
def usd(a,b):
    if a is None or b is None: return ""
    return "%.2f/%.2f" % (round(a*100)/100, round(b*100)/100)
try:
    d=json.load(sys.stdin)
    for v in d.get("data",{}).get("items",[]):
        row=[v.get("id") or "-", v.get("name") or "-",
             round((v.get("utilization_5h") or 0)*100), round((v.get("utilization_7d") or 0)*100),
             str(v.get("reset_5h") or ""), str(v.get("reset_7d") or ""),
             v.get("status_5h") or "unknown", v.get("status_7d") or "unknown",
             usd((v.get("estimate_5h") or {}).get("spent_usd"),(v.get("estimate_5h") or {}).get("total_usd")),
             usd((v.get("estimate_7d") or {}).get("spent_usd"),(v.get("estimate_7d") or {}).get("total_usd"))]
        print("\t".join(str(x) for x in row))
except Exception:
    pass
' 2>/dev/null || true)"
  fi
  printf '%s' "$out"
}

# ---------- output ----------

if [ "$MODE" = "json" ]; then
  if command -v jq >/dev/null 2>&1; then
    if [ -n "$VMS" ]; then
      POOL_PAYLOAD="$(printf '%s' "$VMS" | jq -c '{
        total: .data.total,
        items: [.data.items[]? | {id, name, email, utilization_5h, utilization_7d,
                reset_5h, reset_7d, status_5h, status_7d, estimate_5h, estimate_7d}]}' 2>/dev/null || printf 'null')"
    else
      POOL_PAYLOAD="null"
    fi
    if [ -n "$BILL" ]; then
      BILL_PAYLOAD="$(printf '%s' "$BILL" | jq -c '{
        source: .data.billing.source, currency: .data.billing.currency,
        today: .data.billing.today, window_5h: .data.billing.window_5h,
        total: .data.billing.total}' 2>/dev/null || printf 'null')"
    else
      BILL_PAYLOAD="null"
    fi
    printf '%s' "$USAGE_RESP" | jq -c --argjson pool "$POOL_PAYLOAD" --argjson billing "$BILL_PAYLOAD" \
      '{usage: ., pool: $pool, billing: $billing}' && exit 0
  fi
  # fallback without jq: raw usage JSON only
  printf '%s\n' "$USAGE_RESP"
  exit 0
fi

echo "=== vm2api quota @ ${BASE_URL} ==="
echo "Current account (platform: ${PLATFORM:-n/a}, source: ${SOURCE:-n/a})"
[ -n "$USAGE_NOTE" ] && echo "! ${USAGE_NOTE}"
window_line "5h window:" "$U5" "$S5" "$R5"
window_line "7d window:" "$U7" "$S7" "$R7"

echo ""
echo "=== Per-account quota (pool) ==="
if [ -n "$VMS" ]; then
  ROWS="$(pool_rows)"
  if [ -n "$ROWS" ]; then
    printf '%s\n' "$ROWS" | while IFS="$(printf '\t')" read -r id name u5 u7 r5 r7 s5 s7 e5 e7; do
      echo "- ${id} (${name})"
      if [ -n "$e5" ]; then window_line "  5h window:" "$u5" "$s5" "$r5" "  est \$$e5"; else window_line "  5h window:" "$u5" "$s5" "$r5"; fi
      if [ -n "$e7" ]; then window_line "  7d window:" "$u7" "$s7" "$r7" "  est \$$e7"; else window_line "  7d window:" "$u7" "$s7" "$r7"; fi
    done
  else
    NT="$(RESP="$VMS" jget .data.total)"
    echo "no account rows parsed (pool total=${NT:-?}, jq=$(command -v jq >/dev/null 2>&1 && echo yes || echo no), python3=$(command -v python3 >/dev/null 2>&1 && echo yes || echo no))"
    echo "please report this at the plugin repo with your jq version: $(jq --version 2>/dev/null || echo n/a)"
  fi
else
  echo "unavailable: ${POOL_NOTE}"
fi

echo ""
echo "=== Billing ==="
if [ -n "$BILL" ]; then
  B_CUR="$(RESP="$BILL" jget .data.billing.currency)"
  B_SRC="$(RESP="$BILL" jget .data.billing.source)"
  T_COST="$(RESP="$BILL" jget .data.billing.today.total_cost)"
  T_REQ="$(RESP="$BILL" jget .data.billing.today.requests)"
  T_SINCE="$(RESP="$BILL" jget .data.billing.today_start)"
  W_COST="$(RESP="$BILL" jget .data.billing.window_5h.total_cost)"
  W_REQ="$(RESP="$BILL" jget .data.billing.window_5h.requests)"
  W_SINCE="$(RESP="$BILL" jget .data.billing.window_5h_start)"
  D_COST="$(RESP="$BILL" jget .data.billing.total.total_cost)"
  D_REQ="$(RESP="$BILL" jget .data.billing.total.requests)"
  echo "source: ${B_SRC:-n/a} (${B_CUR:-USD})"
  printf 'today   %s  (%s req, since %s)\n' "$(fmt_usd "$T_COST")" "${T_REQ:-?}" "${T_SINCE:-?}"
  printf '5h win  %s  (%s req, since %s)\n' "$(fmt_usd "$W_COST")" "${W_REQ:-?}" "${W_SINCE:-?}"
  printf '7d win  %s  (%s req)\n' "$(fmt_usd "$D_COST")" "${D_REQ:-?}"
else
  echo "unavailable: ${BILL_NOTE}"
fi
