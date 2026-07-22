#!/usr/bin/env bash
# Bring the remote-agent stack up in the right order, reusing whatever is already
# running, and print a one-time T3 pairing token + the main URL.
#
#   ./start.sh            # 15m pairing token (default)
#   ./start.sh 5m         # custom TTL, passed to t3-pair.sh
#
# Order: prereqs -> caffeinate -> Docker -> Codex token -> proxy -> tunnel ->
# T3 backend + token. Each step is idempotent; a live stack short-circuits to
# reuse paths. See SETUP.md "Step 5" and QUICK-SETUP.md.
set -euo pipefail
cd "$(dirname "$0")"

TTL="${1:-15m}"

# --- a. env ---
[ -f .env ] || { echo ".env missing. Run: cp .env.example .env and fill it in."; exit 1; }
set -a; . ./.env; set +a
: "${T3_HOSTNAME:?set T3_HOSTNAME in .env}"
: "${T3_PORT:?set T3_PORT in .env}"
: "${TUNNEL_NAME:?set TUNNEL_NAME in .env}"

# --- b. prereqs (collect all missing, fail once) ---
missing=()
for c in docker cloudflared claude claudex npx; do
  command -v "$c" >/dev/null 2>&1 || missing+=("$c")
done
if [ "${#missing[@]}" -gt 0 ]; then
  echo "missing prerequisites on PATH: ${missing[*]}"; exit 1
fi

# T3_CHANNEL must match the installed desktop app — the CLI migrates the shared
# ~/.t3 store. Checked here, before Docker/proxy/tunnel come up, so a mismatch
# fails in a second instead of after a full bring-up. Same guard t3-pair.sh runs.
./t3-pair.sh --check-only

# --- c. power + keep-awake ---
if pmset -g batt | grep -q 'AC Power'; then
  echo "on AC power"
else
  echo "WARNING: not on AC power — sleep assertions release when unplugged (see QUICK-SETUP.md)"
fi
if pgrep -f 'caffeinate -dims' >/dev/null; then
  echo "caffeinate -dims already running (reusing)"
else
  nohup caffeinate -dims >/dev/null 2>&1 &
  echo "started caffeinate -dims (display/idle/system awake while on power)"
fi

# --- d. Docker ---
if docker info >/dev/null 2>&1; then
  echo "docker up"
else
  echo "starting Docker Desktop ..."
  # --help is the robust existence guard: `docker desktop status` can exit
  # non-zero simply because Desktop is stopped, which is exactly this case.
  if docker desktop --help >/dev/null 2>&1; then
    docker desktop start --timeout 120 || true
  else
    open -g -j -a Docker
  fi
  echo "waiting for docker daemon (up to 120s) ..."
  for _ in $(seq 1 120); do
    docker info >/dev/null 2>&1 && break
    sleep 1
  done
  docker info >/dev/null 2>&1 || { echo "docker did not come up within 120s"; exit 1; }
  echo "docker up"
fi

# --- e. Codex OAuth token ---
# Valid while now < the ISO-8601 `expired` field (carries a tz offset).
codex_remaining() {
  python3 - "$1" <<'PY'
import sys, json
from datetime import datetime, timezone
try:
    exp = datetime.fromisoformat(json.load(open(sys.argv[1]))["expired"])
except Exception:
    sys.exit(2)
now = datetime.now(timezone.utc)
if now >= exp:
    sys.exit(1)
rem = exp - now
print(f"{rem.days}d {rem.seconds // 3600}h")
PY
}
newest_codex=$(ls -t cliproxy/auth/codex-*.json 2>/dev/null | head -1 || true)
need_login=0
if [ -z "$newest_codex" ]; then
  need_login=1
elif rem=$(codex_remaining "$newest_codex"); then
  echo "codex token valid ($rem left)"
else
  need_login=1
fi
if [ "$need_login" = 1 ]; then
  if [ -t 0 ]; then
    echo "codex token missing or expired — launching ./cliproxy/login.sh (opens the host browser) ..."
    ./cliproxy/login.sh
    newest_codex=$(ls -t cliproxy/auth/codex-*.json 2>/dev/null | head -1 || true)
    if [ -n "$newest_codex" ] && rem=$(codex_remaining "$newest_codex"); then
      echo "codex token valid ($rem left)"
    else
      echo "still no valid codex token after login"; exit 1
    fi
  else
    echo "codex token missing or expired and no TTY — run ./cliproxy/login.sh on the host"; exit 1
  fi
fi

# --- f. proxy ---
echo "starting proxy ..."
./cliproxy/start.sh
KEY=$(grep -oE '[0-9a-f]{64}' cliproxy/config.yaml | head -1)
if ! curl -fsS -H "Authorization: Bearer $KEY" http://127.0.0.1:8317/v1/models >/dev/null 2>&1; then
  echo "proxy up but local API key rejected — check cliproxy/config.yaml"; exit 1
fi
echo "proxy up and key accepted"

# --- g. tunnel ---
# Bringing the tunnel up before the T3 backend deviates from SETUP's "T3 first"
# ordering only by the seconds until step h; Access fronts the hostname and
# t3-pair.sh starts the backend next, so the printed pair link is usable at once.
if pgrep -f "cloudflared tunnel run" >/dev/null; then
  echo "tunnel already running (reusing)"
else
  echo "starting tunnel $TUNNEL_NAME ..."
  nohup cloudflared tunnel run "$TUNNEL_NAME" > /tmp/cloudflared-t3.log 2>&1 &
  for _ in $(seq 1 30); do
    grep -q "Registered tunnel connection" /tmp/cloudflared-t3.log 2>/dev/null && break
    sleep 1
  done
  if ! grep -q "Registered tunnel connection" /tmp/cloudflared-t3.log 2>/dev/null; then
    echo "tunnel did not register within 30s; last log lines:"
    tail -20 /tmp/cloudflared-t3.log
    exit 1
  fi
  echo "tunnel registered"
fi

# --- h. T3 backend + one-time pairing token ---
echo "ensuring T3 backend + minting pairing token ..."
./t3-pair.sh "$TTL"

# --- i. summary ---
cat <<EOF

--- up ---
main URL:   https://$T3_HOSTNAME  (Cloudflare Access, then T3 pairing)
logs:       /tmp/cloudflared-t3.log   /tmp/t3-serve.log
note:       the pair token above is one-time and short-lived — treat it like a password.
            open the Pair URL / paste the token in a browser that has passed Access.
EOF
