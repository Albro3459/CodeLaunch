#!/usr/bin/env bash
# Start the proxy and wait for the loopback listener.
set -euo pipefail
umask 077
cd "$(dirname "$0")"
. ../scripts/env.sh

[ -f config.yaml ] || { echo "config.yaml missing. Run: cp example.config.yaml config.yaml and set your api-key."; exit 1; }

harden_proxy_files() {
  codelaunch_private_file config.yaml
  codelaunch_private_tree auth
}
harden_proxy_files
trap harden_proxy_files EXIT

docker compose up -d

echo "waiting for proxy on 127.0.0.1:8317 ..."
code=000
for _ in $(seq 1 30); do
  code=$(curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:8317/v1/models || true)
  if [ "$code" != "000" ]; then
    echo "proxy up (HTTP $code; 401 without a key is expected)"
    break
  fi
  sleep 1
done
if [ "$code" = "000" ]; then
  echo "proxy did not come up on 127.0.0.1:8317 within 30s"
  docker compose ps
  exit 1
fi

docker compose ps
