#!/usr/bin/env bash
# One-time (and re-auth) Codex OAuth login. Prints a URL to open in the host
# browser; the callback returns to 127.0.0.1:1455. Credentials persist in ./auth.
set -euo pipefail
cd "$(dirname "$0")"

[ -f config.yaml ] || { echo "config.yaml missing. Run: cp example.config.yaml config.yaml and set your api-key."; exit 1; }

docker compose run --rm -p 127.0.0.1:1455:1455 cliproxyapi \
  /CLIProxyAPI/CLIProxyAPI --codex-login
