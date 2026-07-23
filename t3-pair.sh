#!/usr/bin/env bash
# Makes sure a T3 backend is running on loopback, then mints a one-time pairing token for the browser.
#
#   ./t3-pair.sh            # 15m token (default)
#   ./t3-pair.sh 5m         # custom TTL (any t3 --ttl form: 5m, 1h, 30d)
#   ./t3-pair.sh --check-only    # verify T3_CHANNEL vs the desktop app, then exit
#   ./t3-pair.sh --ensure-only   # ensure the loopback backend, then exit
#
# T3_CHANNEL must match the installed desktop app's channel, since both share the ~/.t3 store and a mismatch can break it. Escape hatch: T3_CHANNEL_SKIP_CHECK=1.
set -euo pipefail
umask 077
cd "$(dirname "$0")"
. ./scripts/env.sh

MODE=pair
case "${1:-}" in
  --check-only) MODE=check; shift ;;
  --ensure-only) MODE=ensure; shift ;;
esac
TTL="${1:-15m}"

codelaunch_private_file .env
codelaunch_load_env T3_HOSTNAME T3_PORT T3_CHANNEL T3_CHANNEL_SKIP_CHECK
codelaunch_require_env T3_PORT
if [ "$MODE" = pair ]; then codelaunch_require_env T3_HOSTNAME; fi

: "${T3_CHANNEL:=latest}"
case "$T3_CHANNEL" in
  nightly|latest) ;;
  *) echo "T3_CHANNEL must be 'nightly' or 'latest', got '$T3_CHANNEL'"; exit 1 ;;
esac
PKG="t3@$T3_CHANNEL"

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
  echo "starting headless T3 backend ($PKG) on 127.0.0.1:$T3_PORT ..."
  codelaunch_reset_private_log "$T3_SERVE_LOG"
  npx --yes "$PKG" serve --host 127.0.0.1 --port "$T3_PORT" >"$T3_SERVE_LOG" 2>&1 &
  for _ in $(seq 1 30); do
    listening >/dev/null && break
    sleep 1
  done
  listening >/dev/null || { echo "backend did not come up; see $T3_SERVE_LOG"; exit 1; }
  echo "backend up"
fi

# The tunnel only needs a live loopback listener. Keep the check simple and fail closed if it disappears.
listener_pid=$(lsof -nP -iTCP:"$T3_PORT" -sTCP:LISTEN -t 2>/dev/null | head -1 || true)
if [ -z "$listener_pid" ] || ! ps -p "$listener_pid" -o command= >/dev/null 2>&1; then
  echo "REFUSING: no live backend process owns :$T3_PORT."
  exit 1
fi
non_loopback=$(listening | tail -n +2 | grep -vE '(^|[[:space:]])(127\.0\.0\.1|\[::1\]|::1):' || true)
if [ -n "$non_loopback" ]; then
  echo "REFUSING: backend is not bound exclusively to loopback. Fix before pairing."
  echo "$non_loopback"
  exit 1
fi
echo "backend check ok (PID $listener_pid, loopback only)"

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

cat <<EOF

============================================================
T3 PAIRING
============================================================
CODE:       $credential
PAIR URL:   $pair_url
EXPIRES:    $expires_at

If the QR code does not scan, open the full Pair URL above.
QR CODE:

EOF
if command -v qrencode >/dev/null 2>&1; then
  if ! printf '%s' "$pair_url" | qrencode -t ANSIUTF8 -o -; then
    echo "(QR rendering failed; use the complete Pair URL above.)"
  fi
else
  echo "(qrencode not installed; use the complete Pair URL above.)"
fi
cat <<'EOF'

============================================================
WARNING: This is a one-time secret. Treat the code and URL like a password.
============================================================
EOF
