# Setup

Living command list. Keep updating as each phase lands. Full rationale: `TODO/TODO.md`.

## Step 1 — CLIProxyAPI (Docker)

Prereq: Docker Desktop running (`docker version`, `docker compose version`).

```bash
cp cliproxy/config.example.yaml cliproxy/config.yaml
openssl rand -hex 32                      # generate a key, paste into config.yaml api-keys
```


Set the KEY var to your shell:

```bash
KEY=$(grep -oE '[0-9a-f]{64}' cliproxy/config.yaml | head -1)
```

Codex OAuth login (opens a URL for the host browser; callback -> 127.0.0.1:1455):

```bash
./cliproxy/login.sh
```

Start / status / stop:

```bash
./cliproxy/start.sh                                # up + waits for 127.0.0.1:8317
./cliproxy/stop.sh
```

Verify:

```bash
lsof -nP -iTCP:8317 -sTCP:LISTEN          # expect 127.0.0.1 only, never 0.0.0.0
curl -s -H "Authorization: Bearer <KEY>" http://127.0.0.1:8317/v1/models | head
docker compose -f cliproxy/docker-compose.yml logs --tail=30
```

Status: proxy up on `127.0.0.1:8317`, Codex login OK, all four model IDs confirmed via `/v1/models` (CLIProxyAPI `v7.2.92`, ChatGPT Plus). Inference verified through `gpt-5.6-sol`. Effort `payload.default` verified: default reasoning tracks `high` and yields to an explicit client `low`.

Export the key for later steps (Claude Code / T3):

```bash
export CLIPROXY_LOCAL_API_KEY=<KEY>       # keep out of the repo
```

Notes:
- `config.yaml` and `cliproxy/auth/` are gitignored (key + OAuth creds). Never commit them.
- Effort baselines live in `config.yaml` (`payload.default`): high for sol/luna, medium for 5.5/5.4-mini. Confirm the applied effort in `docker compose logs`, not the client UI.
- Re-auth: rerun `./cliproxy/login.sh`, then `./cliproxy/start.sh`.

## Step 2 — Claudex profile + proxied Claude Code

Profile lives in `~/.claudex` (isolated via `CLAUDE_CONFIG_DIR`): `CLAUDE.md`
(Luna-primary, imports shared `~/.claude/CLAUDE.md`), `settings.json` (model
`opus`, native allowlist, no `effortLevel`), `skills` symlink, and `agents/`
(`gpt-5-6-sol` -> fable, `gpt-5-6-luna` -> opus, `gpt-5-5` -> sonnet,
`gpt-5-4-mini` -> haiku). Launcher: `./claudex` (repo root) sets the proxy env
and runs Claude Code in the current dir.

Add the launcher to your shell once. Example for `~/.zshrc` (pick one):

```zsh
# Option A: alias
alias claudex="$HOME/GitHub/Code/claudex"

# Option B: put the repo dir on PATH
export PATH="$HOME/GitHub/Code:$PATH"

# Option C: symlink into a dir already on PATH (no zshrc edit)
#   ln -s "$HOME/GitHub/Code/claudex" ~/.local/bin/claudex
```

Reload with `source ~/.zshrc`. Then, with the proxy up (`cliproxy/start.sh`),
from any project directory:

```bash
claudex                              # Luna (opus) primary
claudex --model fable                # Sol
claudex --model haiku --effort low   # 5.4 mini, low effort
```

In the session, verify:

- `/status` — `CLAUDE_CONFIG_DIR` is `~/.claudex`, base URL `http://127.0.0.1:8317`, model resolves via `opus` (Luna).
- `/model` — four friendly names appear (GPT-5.6 Sol / Luna, GPT-5.5, GPT-5.4 mini).
- `/agents` — `gpt-5-6-sol`, `gpt-5-6-luna`, `gpt-5-5`, `gpt-5-4-mini` discovered.
- `/effort` — whether levels are selectable (open gate; proxy default is the backstop).

Prove routing from the proxy side while testing:

```bash
docker compose -f cliproxy/docker-compose.yml logs -f
```

Delegate once to each agent and confirm the child requests resolve to Luna /
GPT-5.5 / GPT-5.4 mini in the logs (not just the agent's self-report).

## Step 3 — T3 Code

Install the desktop app and confirm the CLI entrypoint:

```bash
brew install --cask t3-code
npx --yes t3@latest --version
```

Status: `t3-code` 0.0.28 installed as `/Applications/T3 Code (Alpha).app`; CLI
reports the same `v0.0.28`. Cask has `auto_updates` on, so re-check the version
and backend port after it updates. Providers not yet configured.

Get the proxy key to paste into the provider (do not commit it):

```bash
grep -oE '[0-9a-f]{64}' cliproxy/config.yaml | head -1
```

Configure two providers in T3 Desktop. Binary path for both is the stable
symlink, not the versioned target:

```text
/Users/<username>/.local/bin/claude
```

**Claude Native** — that binary path, empty Claude HOME, no environment
variables.

**Claude via CLIProxyAPI** — same binary path, empty Claude HOME, and these
environment variables (values mirror `./claudex`, minus `ANTHROPIC_MODEL`):

```text
CLAUDE_CONFIG_DIR=/Users/<username>/.claudex
ANTHROPIC_BASE_URL=http://127.0.0.1:8317
ANTHROPIC_AUTH_TOKEN=<KEY>
ANTHROPIC_DEFAULT_FABLE_MODEL=gpt-5.6-sol
ANTHROPIC_DEFAULT_FABLE_MODEL_NAME=GPT-5.6 Sol
ANTHROPIC_DEFAULT_FABLE_MODEL_SUPPORTED_CAPABILITIES=effort,xhigh_effort,max_effort
ANTHROPIC_DEFAULT_OPUS_MODEL=gpt-5.6-luna
ANTHROPIC_DEFAULT_OPUS_MODEL_NAME=GPT-5.6 Luna
ANTHROPIC_DEFAULT_OPUS_MODEL_SUPPORTED_CAPABILITIES=effort,xhigh_effort,max_effort
ANTHROPIC_DEFAULT_SONNET_MODEL=gpt-5.5
ANTHROPIC_DEFAULT_SONNET_MODEL_NAME=GPT-5.5
ANTHROPIC_DEFAULT_SONNET_MODEL_SUPPORTED_CAPABILITIES=effort,xhigh_effort
ANTHROPIC_DEFAULT_HAIKU_MODEL=gpt-5.4-mini
ANTHROPIC_DEFAULT_HAIKU_MODEL_NAME=GPT-5.4 mini
ANTHROPIC_DEFAULT_HAIKU_MODEL_SUPPORTED_CAPABILITIES=effort,xhigh_effort
CLAUDE_CODE_ENABLE_GATEWAY_MODEL_DISCOVERY=1
CLAUDE_CODE_MAX_TOOL_USE_CONCURRENCY=3
ENABLE_TOOL_SEARCH=false
```

`./claudex` sets `ANTHROPIC_MODEL=opus` to force Luna as primary. Do not carry
that into T3 — it would pin every thread on this provider to Luna and defeat the
model picker. Pick the model per thread instead.

Verify, with the proxy up:

- Native thread: Fable/Opus/Sonnet/Haiku keep their normal Claude mappings.
- Claudex thread: `/status` shows `~/.claudex` and base URL `127.0.0.1:8317`;
  `/agents` lists the four GPT-named agents.
- Confirm routing in `docker compose -f cliproxy/docker-compose.yml logs -f`,
  not the client's self-report.

Confirm the backend port and that it is loopback-only:

```bash
lsof -nP -iTCP -sTCP:LISTEN | grep -i t3
```

Confirmed: `127.0.0.1:3773`, matching the documented default, with Desktop
Network access off. Re-check after a cask auto-update. If this ever shows
`0.0.0.0`, stop and turn Network access back off before running the tunnel.

Headless fallback, if Desktop's managed backend does not work out:

```bash
npx --yes t3@latest serve --host 127.0.0.1
```

Run only one backend at a time. Pairing tokens and sessions are managed with
`t3 auth pairing` and `t3 auth session`; treat a pairing URL as a password.

## Step 4 — Cloudflare tunnel + Access

Status: `cloudflared 2026.7.2` installed. Nothing configured yet.

Real values live in `.env` (gitignored), not in this file:

```bash
cp .env.example .env      # then fill in, and export for the commands below
```

Order is load-bearing: **Access first, DNS and tunnel second.** Creating the DNS
route before the Access policy exists publishes an unauthenticated agent backend
for however long the gap lasts. New hostnames show up in Certificate
Transparency logs within minutes, so that window is real. Do not reorder for
convenience.

### 4A. Access policy (dashboard, before any ingress)

In Cloudflare Zero Trust: configure an IdP with MFA, then create a self-hosted
Access application for `$T3_HOSTNAME` with exactly one policy:

```text
Action: Allow
Include: Emails -> $ACCESS_EMAIL
Session duration: 1 hour
Independent MFA: required, 1 hour
```

No `Include: Everyone`. No `Bypass` policy. No service tokens. Email OTP alone
allows any valid address — if used, still pin the policy to the exact email.
Test with the intended email and a different email before continuing.

### 4B. Tunnel

```bash
cloudflared tunnel login
cloudflared tunnel create "$TUNNEL_NAME"
cloudflared tunnel list                   # note the UUID
```

Write `~/.cloudflared/config.yml` (outside the repo; credentials JSON stays
local and is never committed):

```yaml
tunnel: <TUNNEL_UUID>
credentials-file: /Users/<username>/.cloudflared/<TUNNEL_UUID>.json

ingress:
  - hostname: code.example.com          # $T3_HOSTNAME
    service: http://127.0.0.1:3773      # $T3_PORT
  - service: http_status:404
```

The catch-all `http_status:404` is required — without it the tunnel refuses to
start, and it ensures no other hostname reaches the origin.

```bash
cloudflared tunnel ingress validate
cloudflared tunnel ingress rule "https://$T3_HOSTNAME"
cloudflared tunnel route dns "$TUNNEL_NAME" "$T3_HOSTNAME"
```

Confirm the CNAME is proxied and points at `<TUNNEL_UUID>.cfargotunnel.com`.

### 4C. Run and verify

Start the proxy and T3 first, then the tunnel:

```bash
cloudflared tunnel run "$TUNNEL_NAME"
```

Do not run `brew services start cloudflared`. That starts it at login, which
contradicts the on-demand orchestration in TODO Phase 6D and would leave ingress
up whenever the Mac is awake.

Verify in this order, from a private window:

- `https://$T3_HOSTNAME` is blocked by Access until the exact email plus MFA.
- A different email is refused.
- After Access passes, a browser with no T3 device session still cannot use the
  backend. This is the layer that matters if Access is ever misconfigured.
- A live agent response streams end to end (WebSocket through the tunnel).
- `lsof -nP -iTCP -sTCP:LISTEN` shows T3 on loopback only, never `0.0.0.0`.

Revoke the test session afterward with `t3 auth session`.
