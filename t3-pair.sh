#!/usr/bin/env bash
# Ensure a single loopback T3 backend is up, then mint a one-time pairing token
# for the browser behind the Cloudflare tunnel. Reuses an existing backend (e.g.
# the desktop app) if one is already listening; otherwise starts a headless one.
#
#   ./t3-pair.sh            # 15m token (default)
#   ./t3-pair.sh 5m         # custom TTL (any t3 --ttl form: 5m, 1h, 30d)
#
# The desktop .app is only a GUI; the backend is the same t3 server. Exactly one
# backend may own the port. The pairing token is issued against the shared ~/.t3
# auth store, so it validates whichever backend is running.
set -euo pipefail
cd "$(dirname "$0")"

[ -f .env ] || { echo ".env missing. Run: cp .env.example .env and fill it in."; exit 1; }
set -a; . ./.env; set +a
: "${T3_HOSTNAME:?set T3_HOSTNAME in .env}"
: "${T3_PORT:?set T3_PORT in .env}"
TTL="${1:-15m}"

listening() { lsof -nP -iTCP:"$T3_PORT" -sTCP:LISTEN 2>/dev/null; }

if listening >/dev/null; then
  echo "T3 backend already listening on :$T3_PORT (reusing)"
else
  echo "starting headless T3 backend on 127.0.0.1:$T3_PORT ..."
  npx --yes t3@nightly serve --host 127.0.0.1 --port "$T3_PORT" >/tmp/t3-serve.log 2>&1 &
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
npx --yes t3@nightly auth pairing create \
  --ttl "$TTL" \
  --label "cloudflare-browser" \
  --base-url "https://$T3_HOSTNAME" 2>&1 | grep -vE 'INFO|Migrations'
