#!/usr/bin/env bash
# Sets up and verifies T3 Connect "publish agent activity" - push notifications and
# Live Activities on your mobile clients, with no managed tunnel.
#
#   ./t3-publish.sh              # first-time setup, headless OAuth (sign in from any device)
#   ./t3-publish.sh --check-only # compare T3_PUBLISH_ACTIVITY against persisted state, then exit
#   ./t3-publish.sh --verify-only # read this boot's t3-serve.log for the link reconcile result
#   ./t3-publish.sh --disable    # stop publishing, keeping the sign-in
#
# Setup state lives in ~/.t3/userdata/secrets, not .env, so it survives stop.sh and reboots.
# `connect status` only reads those files and never contacts the relay, so it cannot tell you
# the stored credential still works. Only --verify-only can: the backend re-mints the
# environment credential from the relay on every start, and logs the outcome.
set -euo pipefail
umask 077
cd "$(dirname "$0")"
. ./scripts/env.sh

usage() {
  cat <<'EOF'
Usage: ./t3-publish.sh
       ./t3-publish.sh --check-only
       ./t3-publish.sh --verify-only
       ./t3-publish.sh --disable
EOF
}

MODE=setup
while [ "$#" -gt 0 ]; do
  case "$1" in
    --check-only|--verify-only|--disable)
      [ "$MODE" = setup ] || { echo "invalid option combination" >&2; usage >&2; exit 2; }
      case "$1" in
        --check-only)  MODE=check ;;
        --verify-only) MODE=verify ;;
        --disable)     MODE=disable ;;
      esac
      shift
      [ "$#" -eq 0 ] || { echo "special mode accepts no other arguments" >&2; usage >&2; exit 2; }
      ;;
    -h|--help) usage; exit 0 ;;
    -*) echo "unknown option: $1" >&2; usage >&2; exit 2 ;;
    *) echo "unexpected argument: $1" >&2; usage >&2; exit 2 ;;
  esac
done

codelaunch_private_file .env
codelaunch_load_env T3_PORT T3_CHANNEL T3_PUBLISH_ACTIVITY
codelaunch_require_env T3_PORT

: "${T3_CHANNEL:=latest}"
case "$T3_CHANNEL" in
  nightly|latest) ;;
  *) echo "T3_CHANNEL must be 'nightly' or 'latest', got '$T3_CHANNEL'"; exit 1 ;;
esac
PKG="t3@$T3_CHANNEL"

: "${T3_PUBLISH_ACTIVITY:=0}"
case "$T3_PUBLISH_ACTIVITY" in
  0|1) ;;
  *) echo "T3_PUBLISH_ACTIVITY must be '0' or '1', got '$T3_PUBLISH_ACTIVITY'"; exit 1 ;;
esac

SETUP_HINT_LOGIN="npx --yes $PKG connect login --headless"
SETUP_HINT_LINK="npx --yes $PKG connect link --publish-only --headless"

# --- persisted state -------------------------------------------------------
# `connect status --json` reads ~/.t3/userdata/secrets only. `authenticated` means a
# credential file is present, not that it still refreshes.
read_status() {
  command -v jq >/dev/null 2>&1 || { echo "missing required dependency: jq"; echo "Install it with: brew install jq"; exit 1; }
  local json
  if ! json=$(npx --yes "$PKG" connect status --json 2>/dev/null); then
    echo "could not read T3 Connect status"
    exit 1
  fi
  if ! printf '%s' "$json" | jq -e '
    type == "object" and
    (.desired | type == "boolean") and
    (.authenticated | type == "boolean") and
    (.linked | type == "boolean") and
    (.publishAgentActivity | type == "boolean")
  ' >/dev/null 2>&1; then
    echo "T3 Connect status returned invalid or incomplete JSON."
    exit 1
  fi
  PUBLISH_ENABLED=$(printf '%s' "$json" | jq -r '.publishAgentActivity')
  LINKED=$(printf '%s' "$json" | jq -r '.linked')
  AUTHENTICATED=$(printf '%s' "$json" | jq -r '.authenticated')
}

if [ "$MODE" = check ]; then
  read_status
  if [ "$T3_PUBLISH_ACTIVITY" = 1 ]; then
    if [ "$PUBLISH_ENABLED" = true ] && [ "$LINKED" = true ] && [ "$AUTHENTICATED" = true ]; then
      echo "publish agent activity ok: enabled and linked"
    else
      echo "WARNING: T3_PUBLISH_ACTIVITY=1 but this machine is not set up to publish."
      [ "$AUTHENTICATED" = true ] || echo "  not signed in to a T3 cloud account"
      [ "$LINKED" = true ] || echo "  environment link not provisioned"
      [ "$PUBLISH_ENABLED" = true ] || echo "  publishing flag is off"
      echo "  Fix: ./t3-publish.sh   (headless OAuth, then restart the stack)"
      echo "  Continuing without push notifications."
    fi
  else
    if [ "$PUBLISH_ENABLED" = true ]; then
      echo "WARNING: T3_PUBLISH_ACTIVITY=0 but this machine is publishing agent activity."
      echo "  Thread and project titles are being sent to relay.t3.codes."
      echo "  Turn it off with: ./t3-publish.sh --disable"
      echo "  Or set T3_PUBLISH_ACTIVITY=1 in .env to declare it on purpose."
    else
      echo "publish agent activity off (T3_PUBLISH_ACTIVITY=0)"
    fi
  fi
  exit 0
fi

# --- this boot's health ----------------------------------------------------
# reconcileDesiredCloudLink runs on every server start: it refreshes the CLI OAuth token,
# then mints a fresh environment credential from the relay. Its result is the only signal
# that the stored credential still works - status keeps reporting "provisioned" off stale
# secrets even when reconcile failed. It is forked behind a retry, so it lands seconds
# after the server reports ready.
RECONCILE_OK='T3 Connect desired link reconciled on startup'
RECONCILE_FAIL='Failed to reconcile T3 Connect desired link on startup'

if [ "$MODE" = verify ]; then
  if [ "$T3_PUBLISH_ACTIVITY" != 1 ]; then exit 0; fi
  codelaunch_prepare_runtime
  T3_SERVE_LOG="$CODELAUNCH_RUNTIME_DIR/t3-serve.log"

  # The desktop app writes its own logs elsewhere, so a t3-serve.log left over from an
  # earlier headless run would describe a process that is no longer the one on the port.
  listener_pid=$(lsof -nP -iTCP:"$T3_PORT" -sTCP:LISTEN -t 2>/dev/null | head -1 || true)
  if [ -z "$listener_pid" ]; then
    echo "note: nothing listening on :$T3_PORT - skipping publish verification"
    exit 0
  fi
  listener_cmd=$(ps -p "$listener_pid" -o command= 2>/dev/null || true)
  case "$listener_cmd" in
    *.app/Contents/*)
      echo "note: :$T3_PORT is served by the T3 desktop app - cannot verify publishing from t3-serve.log"
      exit 0
      ;;
  esac
  if [ ! -f "$T3_SERVE_LOG" ]; then
    echo "note: no $T3_SERVE_LOG - skipping publish verification"
    exit 0
  fi

  : "${T3_PUBLISH_VERIFY_TIMEOUT:=45}"
  case "$T3_PUBLISH_VERIFY_TIMEOUT" in
    ''|*[!0-9]*) echo "T3_PUBLISH_VERIFY_TIMEOUT must be a whole number of seconds"; exit 1 ;;
  esac
  outcome=''
  for _ in $(seq 1 "$T3_PUBLISH_VERIFY_TIMEOUT"); do
    if grep -qF "$RECONCILE_OK" "$T3_SERVE_LOG" 2>/dev/null; then outcome=ok; break; fi
    if grep -qF "$RECONCILE_FAIL" "$T3_SERVE_LOG" 2>/dev/null; then outcome=failed; break; fi
    sleep 1
  done

  case "$outcome" in
    ok)
      echo "publish agent activity verified: relay link reconciled this boot"
      # A publish that fails after a good reconcile is usually the relay being unreachable,
      # not an auth problem, so it is a note rather than a failure.
      failures=$(grep -cF 'agent activity publish failed' "$T3_SERVE_LOG" 2>/dev/null || true)
      : "${failures:=0}"
      if [ "$failures" -gt 0 ]; then
        echo "note: $failures agent activity publish(es) failed since this boot - notifications for those threads were dropped"
        echo "  Detail: grep -A4 'agent activity publish failed' $T3_SERVE_LOG"
      fi
      ;;
    failed)
      echo "WARNING: T3 Connect link reconcile FAILED this boot - push notifications are not working."
      echo "  The stored credential no longer refreshes, or the relay was unreachable at startup."
      echo "  'npx $PKG connect status' will still say 'provisioned' - it reads stale local files."
      echo "  Fix: ./t3-publish.sh   (signs in again, then restart the stack)"
      echo "  Detail: grep -A4 '$RECONCILE_FAIL' $T3_SERVE_LOG"
      ;;
    *)
      echo "note: no T3 Connect reconcile result in $T3_SERVE_LOG after ${T3_PUBLISH_VERIFY_TIMEOUT}s - publishing health unknown"
      echo "  Raise the wait with T3_PUBLISH_VERIFY_TIMEOUT=90 ./start.sh"
      ;;
  esac
  exit 0
fi

# Both remaining modes run the CLI against the shared ~/.t3 store, so guard the channel first.
./t3-pair.sh --check-only

if [ "$MODE" = disable ]; then
  echo "disabling agent activity publishing ..."
  npx --yes "$PKG" connect publish --disable
  echo
  echo "The flag is re-read on every publish, so this takes effect immediately - no restart needed."
  echo "The sign-in and environment link are left in place; re-enable with ./t3-publish.sh."
  if [ "$T3_PUBLISH_ACTIVITY" = 1 ]; then
    echo "Set T3_PUBLISH_ACTIVITY=0 in .env so start.sh stops expecting it."
  fi
  exit 0
fi

# --- setup -----------------------------------------------------------------
if [ ! -t 0 ] || [ ! -t 1 ]; then
  echo "setup needs a TTY - it prompts for an out-of-band authorization code."
  echo "Run ./t3-publish.sh from a terminal, or by hand:"
  echo "  $SETUP_HINT_LOGIN"
  echo "  $SETUP_HINT_LINK"
  exit 1
fi

cat <<EOF

Publishing agent activity sends thread and project titles, phase, a short headline, the
model name, and environment/thread IDs to relay.t3.codes on every meaningful thread event,
tied to your T3 cloud account. The relay forwards to APNs. It does not use your tunnel, and
it does not send code or diffs. This is the one part of CodeLaunch that leaves infrastructure
you control - see SETUP.md.

EOF
printf 'Continue? [y/N] '
IFS= read -r answer || answer=''
case "$answer" in
  y|Y|yes|YES) ;;
  *) echo "aborted"; exit 1 ;;
esac

echo
echo "step 1/2: signing in (headless - open the URL on any device with a browser)"
npx --yes "$PKG" connect login --headless

echo
echo "step 2/2: linking this environment for publishing only (no managed tunnel)"
npx --yes "$PKG" connect link --publish-only --headless

echo
npx --yes "$PKG" connect status

echo
if [ "$T3_PUBLISH_ACTIVITY" != 1 ]; then
  echo "NEXT: set T3_PUBLISH_ACTIVITY=1 in .env, then restart the stack:"
else
  echo "NEXT: restart the stack so the backend provisions the link:"
fi
if lsof -nP -iTCP:"$T3_PORT" -sTCP:LISTEN >/dev/null 2>&1; then
  echo "  ./stop.sh && ./start.sh"
  echo "  (a backend is running on :$T3_PORT - it will not pick this up until it restarts)"
else
  echo "  ./start.sh"
fi
