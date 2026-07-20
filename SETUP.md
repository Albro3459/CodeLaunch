# Setup

Living command list. Keep updating as each phase lands. Full rationale: `TODO/TODO.md`.

## Step 1 — CLIProxyAPI (Docker)

Prereq: Docker Desktop running (`docker version`, `docker compose version`).

```bash
cp cliproxy/config.example.yaml cliproxy/config.yaml
openssl rand -hex 32                      # generate a key, paste into config.yaml api-keys
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

TODO.

## Step 4 — Cloudflare tunnel + Access

TODO.
