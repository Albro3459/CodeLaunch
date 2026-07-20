#!/usr/bin/env bash
# Start the proxy and wait for the loopback listener.
set -euo pipefail
cd "$(dirname "$0")"

[ -f config.yaml ] || { echo "config.yaml missing. Run: cp config.example.yaml config.yaml and set your api-key."; exit 1; }

docker compose up -d

echo "waiting for proxy on 127.0.0.1:8317 ..."
for _ in $(seq 1 30); do
  code=$(curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:8317/v1/models || true)
  if [ "$code" != "000" ]; then
    echo "proxy up (HTTP $code; 401 without a key is expected)"
    break
  fi
  sleep 1
done

docker compose ps
