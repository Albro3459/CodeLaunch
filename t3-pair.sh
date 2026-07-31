#!/usr/bin/env bash
# Ensures the T3 backend matches T3_BIND, then mints a one-time pairing token.
#
#   ./t3-pair.sh            # 15m token (default)
#   ./t3-pair.sh 5m         # custom TTL (any t3 --ttl form: 5m, 1h, 30d)
#   ./t3-pair.sh --check-only    # verify T3_CHANNEL vs the desktop app, then exit
#   ./t3-pair.sh --ensure-only   # ensure the backend, then exit
#
# T3_CHANNEL must match the installed desktop app's channel, since both share the ~/.t3 store and a mismatch can break it. Escape hatch: T3_CHANNEL_SKIP_CHECK=1.
set -euo pipefail
umask 077
cd "$(dirname "$0")"
. ./scripts/env.sh
. ./scripts/pairing.sh

usage() {
  cat <<'EOF'
Usage: ./t3-pair.sh [-d|--detached] [TTL]
       ./t3-pair.sh --check-only
       ./t3-pair.sh --ensure-only
EOF
}

MODE=pair
DETACHED=0
TTL=15m
TTL_SET=0
while [ "$#" -gt 0 ]; do
  case "$1" in
    -d|--detached)
      [ "$MODE" = pair ] && [ "$DETACHED" = 0 ] || { echo "invalid option combination" >&2; usage >&2; exit 2; }
      DETACHED=1; shift
      ;;
    --check-only|--ensure-only)
      [ "$MODE" = pair ] && [ "$TTL_SET" = 0 ] && [ "$DETACHED" = 0 ] || { echo "invalid option combination" >&2; usage >&2; exit 2; }
      case "$1" in
        --check-only) MODE=check ;;
        --ensure-only) MODE=ensure ;;
      esac
      shift
      [ "$#" -eq 0 ] || { echo "special mode accepts no other arguments" >&2; usage >&2; exit 2; }
      ;;
    -h|--help) usage; exit 0 ;;
    -*) echo "unknown option: $1" >&2; usage >&2; exit 2 ;;
    *)
      [ "$MODE" = pair ] && [ "$TTL_SET" = 0 ] || { echo "unexpected argument: $1" >&2; usage >&2; exit 2; }
      TTL=$1; TTL_SET=1; shift
      ;;
  esac
done

codelaunch_private_file .env
codelaunch_load_env T3_HOSTNAME T3_PORT T3_BIND T3_CHANNEL T3_CHANNEL_SKIP_CHECK
codelaunch_require_env T3_PORT
if [ "$MODE" = pair ]; then codelaunch_require_env T3_HOSTNAME; fi

: "${T3_CHANNEL:=latest}"
case "$T3_CHANNEL" in
  nightly|latest) ;;
  *) echo "T3_CHANNEL must be 'nightly' or 'latest', got '$T3_CHANNEL'"; exit 1 ;;
esac
PKG="t3@$T3_CHANNEL"

: "${T3_BIND:=loopback}"
case "$T3_BIND" in
  loopback) BIND_HOST=127.0.0.1 ;;
  all)      BIND_HOST=0.0.0.0 ;;
  *) echo "T3_BIND must be 'loopback' or 'all', got '$T3_BIND'"; exit 1 ;;
esac

listening() { lsof -nP -iTCP:"$T3_PORT" -sTCP:LISTEN 2>/dev/null; }

# --- channel guard ---------------------------------------------------------
# Reads the channel from CFBundleShortVersionString (e.g. 0.0.29-nightly.20260722.875 -> nightly) so a renamed .app still classifies correctly.
app_channel() {
  local ver
  ver=$(defaults read "$1/Contents/Info" CFBundleShortVersionString 2>/dev/null) || return 1
  [ -n "$ver" ] || return 1
  case "$ver" in
    *nightly*) echo "nightly" ;;
    *)         echo "latest" ;;
  esac
}

# Prefers the app that owns the port, since that's the backend the CLI will migrate against, and falls back to scanning installed bundles if nothing is up.
desktop_app=""
running_pid=$(lsof -nP -iTCP:"$T3_PORT" -sTCP:LISTEN -t 2>/dev/null | head -1 || true)
if [ -n "$running_pid" ]; then
  running_cmd=$(ps -p "$running_pid" -o command= 2>/dev/null || true)
  # Strips at the first ".app/" to get the outermost bundle, since Electron helper bundles are nested and have no version string of their own.
  case "$running_cmd" in
    *.app/Contents/*) desktop_app="${running_cmd%%.app/*}.app" ;;
  esac
fi
if [ -z "$desktop_app" ]; then
  found=""
  n=0
  for d in /Applications "$HOME/Applications"; do
    for a in "$d"/T3\ Code*.app; do
      [ -d "$a" ] || continue
      found="$a"
      n=$((n + 1))
    done
  done
  # Only counts when exactly one bundle is installed, since with several we can't guess which one owns the port.
  if [ "$n" -eq 1 ]; then
    desktop_app="$found"
  elif [ "$n" -gt 1 ]; then
    echo "note: multiple T3 Code apps installed - cannot verify T3_CHANNEL against a specific one"
  fi
fi

if [ -n "$desktop_app" ] && [ "${T3_CHANNEL_SKIP_CHECK:-0}" != 1 ]; then
  if app_ch=$(app_channel "$desktop_app"); then
    if [ "$app_ch" != "$T3_CHANNEL" ]; then
      echo "REFUSING: T3_CHANNEL=$T3_CHANNEL but the desktop app is '$app_ch'."
      echo "  app:  $desktop_app"
      echo "  Mismatched channels can corrupt the shared ~/.t3 store during migrations."
      echo "  Fix: set T3_CHANNEL=$app_ch in .env, or install the $T3_CHANNEL cask."
      echo "  Override (not recommended): T3_CHANNEL_SKIP_CHECK=1 ./t3-pair.sh"
      exit 1
    fi
    echo "channel ok: T3_CHANNEL=$T3_CHANNEL matches the desktop app"
  else
    echo "note: could not read a version from $desktop_app - skipping channel check"
  fi
elif [ "${T3_CHANNEL_SKIP_CHECK:-0}" = 1 ]; then
  echo "WARNING: T3_CHANNEL_SKIP_CHECK=1 - channel match not verified"
else
  echo "no T3 desktop app found - using T3_CHANNEL=$T3_CHANNEL for the headless backend"
fi

# Callers that only want the guard, like start.sh's pre-flight check, stop here before anything starts.
if [ "$MODE" = check ]; then exit 0; fi

codelaunch_prepare_runtime
T3_SERVE_LOG="$CODELAUNCH_RUNTIME_DIR/t3-serve.log"

if [ "$MODE" = pair ] && ! command -v jq >/dev/null 2>&1; then
  echo "missing required dependency: jq"
  echo "Install it with: brew install jq"
  exit 1
fi

if listening >/dev/null; then
  echo "T3 backend already listening on :$T3_PORT (reusing)"
else
  echo "starting headless T3 backend ($PKG) on $BIND_HOST:$T3_PORT ..."
  codelaunch_reset_private_log "$T3_SERVE_LOG"
  nohup npx --yes "$PKG" serve --host "$BIND_HOST" --port "$T3_PORT" >"$T3_SERVE_LOG" 2>&1 &
  for _ in $(seq 1 30); do
    listening >/dev/null && break
    sleep 1
  done
  listening >/dev/null || { echo "backend did not come up; see $T3_SERVE_LOG"; exit 1; }
  echo "backend up"
fi

listener_rows=$(listening || true)
listener_pid=$(printf '%s\n' "$listener_rows" | awk 'NR == 2 { print $2 }')
listener_lines=$(printf '%s\n' "$listener_rows" | tail -n +2)
if [ -z "$listener_pid" ] || ! ps -p "$listener_pid" -o command= >/dev/null 2>&1; then
  echo "REFUSING: no live backend process owns :$T3_PORT."
  exit 1
fi
if [ "$T3_BIND" = loopback ]; then
  non_loopback=$(printf '%s\n' "$listener_lines" | grep -vE '(^|[[:space:]])(127\.0\.0\.1|\[::1\]|::1):' || true)
  if [ -n "$non_loopback" ]; then
    echo "REFUSING: T3_BIND=loopback but the backend is bound wider. Fix before pairing."
    echo "$non_loopback"
    exit 1
  fi
  echo "backend check ok (PID $listener_pid, loopback only)"
else
  if ! printf '%s\n' "$listener_lines" | grep -qE '(^|[[:space:]])(\*|0\.0\.0\.0):'"$T3_PORT"'([[:space:]]|$)'; then
    echo "REFUSING: T3_BIND=all but nothing is listening on the wildcard address."
    echo "  Restart the backend with ./stop.sh && ./start.sh"
    printf '%s\n' "$listener_lines"
    exit 1
  fi
  echo "backend check ok (PID $listener_pid, wildcard bind)"
fi

if [ "$MODE" = ensure ]; then exit 0; fi

echo "minting pairing token (ttl $TTL) ..."
if ! pairing_json=$(npx --yes "$PKG" auth pairing create \
  --ttl "$TTL" \
  --label "cloudflare-browser" \
  --base-url "https://$T3_HOSTNAME" \
  --json); then
  echo "T3 pairing command failed."
  exit 1
fi

if ! printf '%s' "$pairing_json" | jq -e '
  type == "object" and
  (.credential | type == "string" and length > 0) and
  (.pairUrl | type == "string" and length > 0) and
  (.expiresAt | (type == "string" or type == "number"))
' >/dev/null 2>&1; then
  echo "T3 pairing command returned invalid or incomplete JSON."
  echo "Expected credential, pairUrl, and expiresAt fields."
  exit 1
fi

credential=$(printf '%s' "$pairing_json" | jq -r '.credential')
pair_url=$(printf '%s' "$pairing_json" | jq -r '.pairUrl')
expires_at=$(printf '%s' "$pairing_json" | jq -r '.expiresAt')

codelaunch_pairing_present "$credential" "$expires_at" "$pair_url" "$T3_PORT" "$T3_BIND" "$DETACHED"
