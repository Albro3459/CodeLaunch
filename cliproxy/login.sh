#!/usr/bin/env bash
# One-time (and re-auth) Codex OAuth login. Prints a URL to open in the host
# browser; the callback returns to 127.0.0.1:1455. Credentials persist in ./auth.
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

docker compose run --rm -p 127.0.0.1:1455:1455 cliproxyapi \
  /CLIProxyAPI/CLIProxyAPI --codex-login
