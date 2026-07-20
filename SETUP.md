# Setup

Living command list. Keep updating as each phase lands. Full rationale: `TODO/TODO.md`.

## Step 1 — CLIProxyAPI (Docker)

Prereq: Docker Desktop running (`docker version`, `docker compose version`).

```bash
cd cliproxy
cp config.example.yaml config.yaml
openssl rand -hex 32                      # generate a key, paste into config.yaml api-keys
```

Codex OAuth login (opens a URL for the host browser; callback -> 127.0.0.1:1455):

```bash
./login.sh
```

Start / status / stop:

```bash
./start.sh                                # up + waits for 127.0.0.1:8317
./stop.sh
```

Verify:

```bash
lsof -nP -iTCP:8317 -sTCP:LISTEN          # expect 127.0.0.1 only, never 0.0.0.0
curl -s -H "Authorization: Bearer <KEY>" http://127.0.0.1:8317/v1/models | head
docker compose -f cliproxy/docker-compose.yml logs --tail=30
```

Export the key for later steps (Claude Code / T3):

```bash
export CLIPROXY_LOCAL_API_KEY=<KEY>       # keep out of the repo
```

Notes:
- `config.yaml` and `cliproxy/auth/` are gitignored (key + OAuth creds). Never commit them.
- Effort baselines live in `config.yaml` (`payload.default`): high for sol/luna, medium for 5.5/5.4-mini. Confirm the applied effort in `docker compose logs`, not the client UI.
- Re-auth: rerun `./login.sh`, then `./start.sh`.

## Step 2 — Claudex profile + proxied Claude Code

TODO.

## Step 3 — T3 Code

TODO.

## Step 4 — Cloudflare tunnel + Access

TODO.
