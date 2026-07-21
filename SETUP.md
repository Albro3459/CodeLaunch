# Setup

Living command list. Keep updating as each phase lands. Full rationale: `TODO/TODO.md`.

## Step 1 - CLIProxyAPI (Docker)

Prereq: Docker Desktop running (`docker version`, `docker compose version`).

```bash
cp cliproxy/example.config.yaml cliproxy/config.yaml
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

Status: proxy up on `127.0.0.1:8317`, Codex login OK, all four models confirmed via `/v1/models` (CLIProxyAPI `v7.2.92`, ChatGPT Plus). Inference verified through every model and every role.

Models are exposed under two sets of aliases (`oauth-model-alias`), and the raw upstream ids no longer route:

- **Friendly names** — `GPT-5.6 Sol`, `GPT-5.6 Luna`, `GPT 5.5`, `GPT 5.4 mini`. Required by the `ANTHROPIC_DEFAULT_*_MODEL` role mappings in `claudex`, and the only labels that honestly report which model is serving you.
- **Claude slugs** — `claude-fable-5`, `claude-opus-4-8`, `claude-sonnet-4-6`, `claude-haiku-4-5` and friends, each pointing at the same upstream model as its friendly counterpart. These exist solely so T3 will pass reasoning effort; see Step 3.

One upstream id can carry many aliases and they all coexist — `/v1/models` lists all 14. Use the friendly names from the CLI and the Claude slugs from T3.

Export the key for later steps (Claude Code / T3):

```bash
export CLIPROXY_LOCAL_API_KEY=<KEY>       # keep out of the repo
```

Notes:
- `config.yaml` and `cliproxy/auth/` are gitignored (key + OAuth creds). Never commit them. Nothing in the alias/effort setup is recoverable from git if that file is lost.
- **Aliases replace the upstream id, but many aliases can share one id.** After aliasing, the raw id returns `unknown provider`; unaliased models keep their own ids. Keep `oauth-model-alias` in sync with `ANTHROPIC_DEFAULT_*_MODEL` in `../claudex`, or role lookups fail with a `502 unknown provider` that Claude Code retries as if it were transient. `customModels` in `~/.t3/userdata/settings.json` does **not** need to match — T3 lists built-in Claude models regardless, and custom entries there are actively harmful (Step 3).
- **An alias differing only by case is silently ignored.** `gpt-5.6-luna` -> `GPT-5.6-Luna` is a no-op with nothing logged and the original left in place; `GPT-5.6 Luna` works. Every alias must differ by a real character, which is why `GPT 5.5` carries a space.
- **`payload.default` effort is a no-op here.** It fills `reasoning.effort` only when the client omits it, but the `/v1/messages` -> codex translation always derives a level first. Verified with `debug: true`: a request with no thinking field arrives as `level=medium`, and Luna logs `medium` despite its `high` baseline. Effort is controlled by the client (`/effort`, per-agent frontmatter), not the proxy. Do not switch to `override` — it force-replaces client values and would break per-agent effort.
- **To inspect applied effort**, uncomment `debug` / `logging-to-file` / `request-log` in `config.yaml` and restart. Each call writes `cliproxy/auth/logs/v1-messages-*.log` containing both the incoming Claude request and the translated upstream codex body:

  ```bash
  for g in $(ls -t cliproxy/auth/logs/v1-messages-*.log | grep -v count_tokens | head -3); do
    echo "== $(basename $g)"
    grep -oE '"model":"[^"]*"' "$g" | head -2 | tr '\n' ' '; echo
    grep -oE '"reasoning":\{"effort":"[a-z]*"' "$g" | head -1
  done
  ```

  First model is what the client asked for, second is what actually ran. Turn logging back off when done — these files hold full request bodies, including whole conversations. Background calls Claude Code makes on its own (session titles) send no thinking field and land at `medium`; that is normal and not a sign effort failed.
- Re-auth: rerun `./cliproxy/login.sh`, then `./cliproxy/start.sh`.

## Step 2 - Claudex profile + proxied Claude Code

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

- `/status` - `CLAUDE_CONFIG_DIR` is `~/.claudex`, base URL `http://127.0.0.1:8317`, model resolves via `opus` (Luna).
- `/model` - four friendly names appear (GPT-5.6 Sol / Luna, GPT-5.5, GPT-5.4 mini).
- `/agents` - `gpt-5-6-sol`, `gpt-5-6-luna`, `gpt-5-5`, `gpt-5-4-mini` discovered.
- `/effort` - levels are selectable and do apply. `ANTHROPIC_DEFAULT_*_SUPPORTED_CAPABILITIES` in the wrapper is what tells Claude Code these custom model names accept effort; without it the flag is ignored. Verified: `claudex --model haiku --effort low` arrives upstream as `reasoning.effort: low`, `--effort max` as `xhigh`. There is no proxy-side backstop — `payload.default` is a no-op.

Prove routing from the proxy side while testing:

```bash
docker compose -f cliproxy/docker-compose.yml logs -f
```

Delegate once to each agent and confirm the child requests resolve to Luna /
GPT-5.5 / GPT-5.4 mini in the logs (not just the agent's self-report).

## Step 3 - T3 Code

Install the desktop app and confirm the CLI entrypoint:

```bash
brew install --cask t3-code
npx --yes t3@latest --version
```

Status: `t3-code` 0.0.28 installed as `/Applications/T3 Code (Alpha).app`; CLI
reports the same `v0.0.28`. Cask has `auto_updates` on, so re-check the version
and backend port after it updates.

Configure two providers in T3 Desktop.

**Claude Native** - leave as installed. T3 resolves the bare `claude` name on
its own.

**Claudex** - point at the wrapper, and leave every other field empty:

```text
Display name: Claudex
Binary path:  /Users/<username>/.local/bin/claudex
Claude HOME path: empty
Environment variables: none
```

Two things this gets right, both of which fail silently otherwise:

- **The path must be absolute.** T3 spawns the binary directly, with no shell,
  so `~` is never expanded and `~/.local/bin/claudex` fails with
  `spawn ... ENOENT`. Bare `claude` works only because T3 has its own lookup for
  the default name; a custom name gets no such treatment.
- **Claude HOME must stay empty.** Despite the name, that field sets `HOME`, not
  `CLAUDE_CONFIG_DIR` - the app's own description says "Custom HOME used when
  running this Claude instance." Setting it to `~/.claudex` makes the wrapper
  compute `CLAUDE_CONFIG_DIR="$HOME/.claudex"` = `~/.claudex/.claudex`, and
  Claude starts with no CLAUDE.md, no agents, and no model mappings. The wrapper
  sets the config dir itself.

No environment variables go in T3. `claudex` supplies the base URL, key, and
model mappings, so the proxy key never enters T3's secret store and the mapping
has one source of truth. T3 passes the picked model as a `--model` launch
argument, which overrides the wrapper's `ANTHROPIC_MODEL=opus`, so the model
picker still works.

Provider config is stored at `~/.t3/userdata/settings.json`. T3 rewrites that
file on quit, so edit it only while the app is closed - otherwise use the GUI.

### Reasoning effort in T3: pick the Claude-named models

**T3 silently drops effort for custom models.** Its `claudeAgent` driver only
passes `effort` to the Agent SDK for built-in Claude model slugs. Custom models
resolve to `DEFAULT_CLAUDE_MODEL_CAPABILITIES`, an empty descriptor list, so
`resolveClaudeEffort` returns undefined and the reasoning selection never leaves
T3. No proxy setting can recover it. This is why a thread on `GPT-5.6 Luna`
always ran at the default no matter what the reasoning control said.

The fix is the second alias block in `config.yaml`: the upstream models are also
aliased to built-in Claude slugs, so selecting one makes T3 attach effort.

- In the model picker choose the **Claude-named** entries, not the `GPT ...`
  ones. `Claude Opus 4.8` -> Luna, `Claude Fable 5` -> Sol,
  `Claude Sonnet 4.6` -> GPT-5.5, `Claude Haiku 4.5` -> 5.4 mini.
- **Empty `customModels`** for the claudex instance. The `GPT ...` entries are
  the only way to pick a model that ignores effort, and they look identical to
  the working ones in the UI. Removing them from T3 costs nothing —
  `claudex --model 'GPT-5.6 Sol'` still works from a terminal.
- Levels map `low` -> `low`, `medium` -> `medium`, `high` -> `high`,
  `max` -> `xhigh`. Haiku 4.5 exposes only a thinking toggle in T3, so 5.4 mini
  gets no effort control through the app; use the CLI for that.
- Fast Mode on the Opus entries is untested against the proxy. Leave it off.

**The model will lie about its identity under these slugs.** Claude Code's
system prompt asserts it is Claude and the model id now agrees, so asking
"what model are you?" returns a confident wrong answer — a thread on
`claude-opus-4-8` is really GPT-5.6 Luna. Anything keyed on model identity
(the `claude-api` skill, model-conditional agent frontmatter) will misfire
toward Claude behaviour. The proxy logs are the only ground truth. This is the
unavoidable cost of getting effort through T3; the CLI keeps honest labels.

Verify a T3 thread end to end by enabling request logging (Step 1 notes), then
sending one message at low reasoning. Expect the incoming model to be the Claude
slug, the upstream model to be the GPT id, and `reasoning.effort` to be `low`.

Verify, with the proxy up:

- Native thread: Fable/Opus/Sonnet/Haiku keep their normal Claude mappings.
- Claudex thread: `/status` shows `~/.claudex` and base URL `127.0.0.1:8317`;
  `/agents` lists the four GPT-named agents.
- Claudex thread on a Claude-named model with reasoning set to low: the request
  log shows `reasoning.effort: low` against the GPT upstream id.
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

## Step 4 - Cloudflare tunnel + Access

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
allows any valid address - if used, still pin the policy to the exact email.
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

The catch-all `http_status:404` is required - without it the tunnel refuses to
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
