#!/usr/bin/env bash
# Ensure a single loopback T3 backend is up, then mint a one-time pairing token
# for the browser behind the Cloudflare tunnel. Reuses an existing backend (e.g.
# the desktop app) if one is already listening; otherwise starts a headless one.
#
#   ./t3-pair.sh            # 15m token (default)
#   ./t3-pair.sh 5m         # custom TTL (any t3 --ttl form: 5m, 1h, 30d)
#   ./t3-pair.sh --check-only   # verify T3_CHANNEL vs the desktop app, then exit
#
# The desktop .app is only a GUI; the backend is the same t3 server. Exactly one
# backend may own the port. The pairing token is issued against the shared ~/.t3
# auth store, so it validates whichever backend is running.
#
# T3_CHANNEL (.env, default latest) picks the npm dist-tag for both commands. It
# MUST match the installed desktop app's channel: both share the ~/.t3 store and
# the CLI runs schema migrations against it, so a mismatch can migrate the store
# to a schema the other side does not understand. This script enforces that and
# refuses to run on a mismatch. Escape hatch: T3_CHANNEL_SKIP_CHECK=1.
set -euo pipefail
cd "$(dirname "$0")"

[ -f .env ] || { echo ".env missing. Run: cp .env.example .env and fill it in."; exit 1; }
set -a; . ./.env; set +a
: "${T3_HOSTNAME:?set T3_HOSTNAME in .env}"
: "${T3_PORT:?set T3_PORT in .env}"
: "${T3_CHANNEL:=latest}"
case "$T3_CHANNEL" in
  nightly|latest) ;;
  *) echo "T3_CHANNEL must be 'nightly' or 'latest', got '$T3_CHANNEL'"; exit 1 ;;
esac
PKG="t3@$T3_CHANNEL"
CHECK_ONLY=0
if [ "${1:-}" = "--check-only" ]; then CHECK_ONLY=1; shift; fi
TTL="${1:-15m}"

listening() { lsof -nP -iTCP:"$T3_PORT" -sTCP:LISTEN 2>/dev/null; }

# --- channel guard ---------------------------------------------------------
# Resolve a desktop app bundle to its channel via CFBundleShortVersionString
# (e.g. 0.0.29-nightly.20260722.875 -> nightly). The version string is the
# signal, not the bundle name, so a renamed .app is still classified correctly.
app_channel() {
  local ver
  ver=$(defaults read "$1/Contents/Info" CFBundleShortVersionString 2>/dev/null) || return 1
  [ -n "$ver" ] || return 1
  case "$ver" in
    *nightly*) echo "nightly" ;;
    *)         echo "latest" ;;
  esac
}

# Prefer the app that actually owns the port — that is the backend the CLI will
# migrate against. Fall back to a scan of installed bundles when nothing is up.
desktop_app=""
running_pid=$(lsof -nP -iTCP:"$T3_PORT" -sTCP:LISTEN -t 2>/dev/null | head -1 || true)
if [ -n "$running_pid" ]; then
  running_cmd=$(ps -p "$running_pid" -o command= 2>/dev/null || true)
  # Strip at the FIRST ".app/" to get the OUTERMOST bundle: Electron helper
  # processes live in nested bundles whose Info.plist has no version string,
  # which would silently skip this check.
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
  # Exactly one installed bundle is unambiguous; with several we cannot know
  # which one will own the port, so warn instead of guessing.
  if [ "$n" -eq 1 ]; then
    desktop_app="$found"
  elif [ "$n" -gt 1 ]; then
    echo "note: multiple T3 Code apps installed — cannot verify T3_CHANNEL against a specific one"
  fi
fi

if [ -n "$desktop_app" ] && [ "${T3_CHANNEL_SKIP_CHECK:-0}" != 1 ]; then
  if app_ch=$(app_channel "$desktop_app"); then
    if [ "$app_ch" != "$T3_CHANNEL" ]; then
      echo "REFUSING: T3_CHANNEL=$T3_CHANNEL but the desktop app is '$app_ch'."
      echo "  app:  $desktop_app"
      echo "  The CLI and the desktop backend share ~/.t3 and the CLI runs schema"
      echo "  migrations against it — mismatched channels can corrupt that store."
      echo "  Fix: set T3_CHANNEL=$app_ch in .env, or install the $T3_CHANNEL cask."
      echo "  Override (not recommended): T3_CHANNEL_SKIP_CHECK=1 ./t3-pair.sh"
      exit 1
    fi
    echo "channel ok: T3_CHANNEL=$T3_CHANNEL matches the desktop app"
  else
    echo "note: could not read a version from $desktop_app — skipping channel check"
  fi
elif [ "${T3_CHANNEL_SKIP_CHECK:-0}" = 1 ]; then
  echo "WARNING: T3_CHANNEL_SKIP_CHECK=1 — channel match not verified"
else
  echo "no T3 desktop app found — using T3_CHANNEL=$T3_CHANNEL for the headless backend"
fi

# Callers that only want the guard (start.sh, pre-flight) stop here — no backend
# is started and no token is minted.
if [ "$CHECK_ONLY" = 1 ]; then exit 0; fi

if listening >/dev/null; then
  echo "T3 backend already listening on :$T3_PORT (reusing)"
else
  echo "starting headless T3 backend ($PKG) on 127.0.0.1:$T3_PORT ..."
  npx --yes "$PKG" serve --host 127.0.0.1 --port "$T3_PORT" >/tmp/t3-serve.log 2>&1 &
  for _ in $(seq 1 30); do
    listening >/dev/null && break
    sleep 1
  done
  listening >/dev/null || { echo "backend did not come up; see /tmp/t3-serve.log"; exit 1; }
  echo "backend up"
fi

# Never expose beyond loopback. The tunnel connects from localhost, so 0.0.0.0
# is never needed and would put the backend on the LAN.
if listening | grep -q '0.0.0.0'; then
  echo "REFUSING: backend is bound to 0.0.0.0, not loopback. Fix before pairing."
  exit 1
fi

echo "minting pairing token (ttl $TTL) ..."
npx --yes "$PKG" auth pairing create \
  --ttl "$TTL" \
  --label "cloudflare-browser" \
  --base-url "https://$T3_HOSTNAME" 2>&1 | grep -vE 'INFO|Migrations'
