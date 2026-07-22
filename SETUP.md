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
- **Claude slugs** — `claude-fable-5`, `claude-opus-4-8`, `claude-sonnet-5`, `claude-haiku-4-5` and friends, each pointing at the same upstream model as its friendly counterpart. These exist solely so T3 will pass reasoning effort; see Step 3.

One upstream id can carry many aliases and they all coexist — `/v1/models` lists all 16. Use the friendly names from the CLI and the Claude slugs from T3.

Export the key for later steps (Claude Code / T3):

```bash
export CLIPROXY_LOCAL_API_KEY=<KEY>       # keep out of the repo
```

Notes:
- `config.yaml` and `cliproxy/auth/` are gitignored (key + OAuth creds). Never commit them. The alias/effort setup itself *is* in git — `example.config.yaml` is identical to `config.yaml` apart from the placeholder key and a leading comment, so a lost `config.yaml` is one `cp` away from working. The local API key is regenerable in seconds (`openssl rand -hex 32`); only the Codex OAuth credentials under `auth/` need a re-login to replace. Keep `example.config.yaml` in sync whenever `config.yaml` changes.
- **Aliases replace the upstream id, but many aliases can share one id.** After aliasing, the raw id returns `unknown provider`; unaliased models keep their own ids. Keep `oauth-model-alias` in sync with `ANTHROPIC_DEFAULT_*_MODEL` in `../claudex`, or role lookups fail with a `502 unknown provider` that Claude Code retries as if it were transient. `customModels` in `~/.t3/userdata/settings.json` does **not** need to match — T3 lists built-in Claude models regardless, and custom entries there are actively harmful (Step 3).
- **`config.yaml` edits need a container restart.** The file is a read-only bind mount (`./config.yaml:/CLIProxyAPI/config.yaml:ro`), and the process reads it at startup. Run `./cliproxy/stop.sh` then `./cliproxy/start.sh` (`docker compose down`, then `up -d` plus the listener poll). `start.sh` on its own does not recreate an already-running container, so the old alias table stays live.
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

Status: `t3-code` `0.0.29-nightly.20260721.864` installed as
`/Applications/T3 Code (Nightly).app`. The old `T3 Code (Alpha)` name survives in
the app as `legacyUserDataDirName`, so it still shows up as a userdata directory.
Cask has `auto_updates` on, so re-check the version and backend port after it
updates.

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
- **Claude HOME must stay empty.** The field is inert either way — the wrapper's
  `exec env CLAUDE_CONFIG_DIR=...` overrides whatever T3 puts in the child
  environment — so filling it in can only mislead. On `0.0.29-nightly`,
  `makeClaudeEnvironment` returns the base environment untouched when the field
  is blank and otherwise sets `CLAUDE_CONFIG_DIR` to the resolved path. It never
  sets `HOME`, despite the app's description ("Custom HOME used when running this
  Claude instance"). Documented earlier against 0.0.28 as setting `HOME`, which
  would have made the wrapper compute `CLAUDE_CONFIG_DIR="$HOME/.claudex"` =
  `~/.claudex/.claudex`; that reading is superseded by the current build. Could
  be a behavior change rather than an original error, so re-check after a cask
  update.

No environment variables go in T3. `claudex` supplies the base URL, key, and
model mappings, so the proxy key never enters T3's secret store and the mapping
has one source of truth. T3 passes the picked model as a `--model` launch
argument, which overrides the wrapper's `ANTHROPIC_MODEL=opus`, so the model
picker still works.

**T3's environment fields do not just go unused here — they are overridden.**
The wrapper ends in `exec env -u ANTHROPIC_API_KEY VAR=... "$CLAUDE_BIN" "$@"`.
Those are literal assignments on the `env` command line, so they win over
anything T3 exports into the child. Setting `ANTHROPIC_BASE_URL` or any
`ANTHROPIC_DEFAULT_*` in T3 has no effect at all, with nothing logged to say so;
the wrapper is the only place those values can be changed. `ANTHROPIC_API_KEY`
is explicitly removed with `env -u`, so an inherited key cannot leak in either.
Three variables are read from the environment on purpose, before the `exec`:

- `CLIPROXY_LOCAL_API_KEY` — overrides the key scraped from `config.yaml`.
- `CLAUDE_BIN` — overrides which `claude` binary is launched.
- `HOME` — the wrapper computes `CLAUDE_CONFIG_DIR="$HOME/.claudex"` from it, so
  anything that moves `HOME` moves the whole profile. The current build's Claude
  HOME path field does not touch `HOME`, but leave it empty per the rule above.

Provider config is stored at `~/.t3/userdata/settings.json`. T3 rewrites that
file on quit, so edit it only while the app is closed - otherwise use the GUI.

### Install the templates instead of clicking through the GUI

`.t3/` in this repo holds working copies of both files T3 reads. Quit T3
completely first. `client-settings.json` works differently from the settings file
above: there is no quit-time flush, it is read once at startup and rewritten
atomically on the next settings change. A copy made while the app is running is
therefore ignored until a restart, then clobbered by the next favorite toggle or
word-wrap change.

From the repo root:

```bash
mkdir -p ~/.t3/userdata
cp .t3/example.settings.json        ~/.t3/userdata/settings.json
cp .t3/example.client-settings.json ~/.t3/userdata/client-settings.json
```

**This overwrites the existing T3 settings**, including every other configured
provider and all favorites. Back both files up first if there is a T3 setup
worth keeping.

Then fix `binaryPath` in `~/.t3/userdata/settings.json`. The template ships the
literal placeholder `/Users/<username>/.local/bin/claudex`; left as-is T3 fails
with `spawn ... ENOENT`, for the absolute-path reason above. Replace it with the
real path.

`example.client-settings.json` carries picker state rather than provider config:
favorites for `claudeAgent` and `claudex` on `claude-fable-5` and
`claude-opus-4-8`, plus `providerModelPreferences.claudex.hiddenModels`, which
hides `claude-opus-4-7`, `claude-opus-4-6`, `claude-opus-4-5` and
`claude-sonnet-4-6` from the claudex picker.

`claude-sonnet-5` stays **visible**: it is the Sonnet route to GPT-5.5, and it is
also `DEFAULT_MODEL_BY_PROVIDER[claudeAgent]`, so a fresh claudex thread lands on
it. `config.yaml` aliases both `claude-sonnet-5` and `claude-sonnet-5[1m]` — the
latter is required because that row carries a `contextWindow` selector (200k
default / 1m) and picking 1M makes T3 send the id with `[1m]` appended; without
the second alias that selection returns `502 unknown provider`, which Claude Code
retries as if it were transient.

`claude-opus-4-7` and `claude-opus-4-5` are duplicate aliases of Luna, so hiding
them only removes clutter. The other two each cost something:

- `claude-opus-4-6` is the only Opus row that exposes a `contextWindow` selector
  (200k/1m); `claude-opus-4-8` has none. `config.yaml` aliases
  `claude-opus-4-6[1m]`, so hiding it gives up the only 1M-context route to Luna
  in T3. Accepted tradeoff.
- `claude-sonnet-4-6` is still aliased to GPT-5.5 and works, but `claude-sonnet-5`
  supersedes it: 4.6 is the one slug where `normalizeClaudeCliEffort` rewrites
  `max` -> `high`, so its top effort level is silently unreachable. Two identical
  Sonnet rows with different effort ceilings is a trap, so the weaker one is
  hidden.

Drop any of these from `hiddenModels` to make them pickable again.

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
  `Claude Sonnet 5` -> GPT-5.5, `Claude Haiku 4.5` -> 5.4 mini.
- **Empty `customModels`** for the claudex instance. The `GPT ...` entries are
  the only way to pick a model that ignores effort, and they look identical to
  the working ones in the UI. Removing them from T3 costs nothing —
  `claudex --model 'GPT-5.6 Sol'` still works from a terminal.
- **T3 remaps effort before sending it.** The selector offers `low`, `medium`,
  `high`, `xhigh`, `max`, `ultracode` and `ultrathink`, but
  `normalizeClaudeCliEffort` rewrites the selection on the way out (both the CLI
  and SDK paths, via `getEffectiveClaudeAgentEffort`): `ultrathink` sends nothing
  at all, `ultracode` -> `xhigh`, and `xhigh` -> `max` for every model except
  `claude-fable-5`, `claude-opus-4-8` and `claude-sonnet-5`. `low`, `medium` and
  `high` pass through unchanged, and `claude-sonnet-5` additionally passes both
  `xhigh` and `max` through untouched — it is exempt from the `xhigh` -> `max`
  rewrite and from the `max` -> `high` rewrite.
- **`max` downgrades on `claude-sonnet-4-6` only.** `max` -> `high` there, so
  picking "Max" on that row actually sends `high`; `xhigh` maps up to `max`.
  That row is hidden by default for this reason.
- **Do not pick "Max" on the Sonnet 5 row - it fails.** Upstream `gpt-5.5`
  supports `none, low, medium, high, xhigh` and has **no** `max`. On
  `claude-sonnet-4-6` T3's `max` -> `high` rewrite accidentally hid that;
  `claude-sonnet-5` has no such rewrite, so selecting "Max" sends a literal `max`
  to a model that does not advertise it. Tested: the request errors rather than
  falling back to a default (the `payload.default` effort only fills an *omitted*
  level, and "Max" sends one explicitly, so there is no backstop). **`xhigh` is
  the top usable level on the Sonnet 5 row.** T3 gives no way to remove `max`
  from the picker - the effort list is baked into the built-in slug's descriptor
  and `hiddenModels` only hides whole rows - so this is a discipline constraint,
  not something the config can enforce.
- Haiku 4.5 exposes only a thinking toggle in T3, so 5.4 mini gets no effort
  control through the app; use the CLI for that.
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

Status: `cloudflared 2026.7.2` installed. Nothing configured yet - no zone
authorized to `cloudflared`, no tunnel created, no Access application.

Real values live in `.env` (gitignored), not in this file:

```bash
cp .env.example .env      # then fill in, and export for the commands below
```

Order is load-bearing: **Access first, DNS and tunnel second.** Creating the DNS
route before the Access policy exists publishes an unauthenticated agent backend
for however long the gap lasts. New hostnames show up in Certificate
Transparency logs within minutes, so that window is real. Do not reorder for
convenience.

### 4.0 Prerequisites

Everything below assumes these hold. Each one fails late and unhelpfully if it
does not.

**Domain is an active zone in Cloudflare.** The registrar's nameservers have to
be delegated to Cloudflare and the change has to have propagated. Check before
anything else:

```bash
dig +short NS <your-domain> @1.1.1.1
```

Query a public resolver explicitly - a local or ISP resolver can still be serving
a cached pre-delegation answer. Expect Cloudflare nameservers
(`*.ns.cloudflare.com`). If the registrar's own nameservers come back, delegation
has not landed yet and `cloudflared tunnel login` will likely not offer the zone
at all; the expected symptom is an absence from the zone list rather than an
error, but that is unverified here.

**A Cloudflare Zero Trust organization exists.** One-time setup in the
dashboard; it produces a team domain `<team>.cloudflareaccess.com`. The Access
application in 4A cannot be created without it. The free tier covers this
setup.

**`cloudflared` is on PATH.**

```bash
cloudflared --version
```

**`cloudflared tunnel login` is the auth boundary.** It opens a browser, asks
which zone to authorize, and writes `~/.cloudflared/cert.pem` - the certificate
every later `tunnel create`/`route dns` call uses. Pick the zone verified above.
The command itself is run in 4B.

**Export the `.env` values into the current shell.** Step 4 refers to
`$T3_HOSTNAME`, `$T3_PORT`, `$TUNNEL_NAME` and `$ACCESS_EMAIL` throughout, but
`cp .env.example .env` only creates the file - it exports nothing, so those
commands would run with empty strings substituted in. Load it explicitly, from
the repo root, in every shell that runs a Step 4 command:

```bash
set -a; . ./.env; set +a
```

**T3 must already be serving on `$T3_PORT`.** `cloudflared tunnel run` connects
to the edge whether or not anything is listening at the origin, so a missing
backend is not a tunnel failure. Access sits in front, so the failure only shows
up after authenticating: expect Cloudflare error 1033 when no tunnel is running
or the hostname is misrouted, and a 502 only once the tunnel is up but the origin
port is dead. Start Desktop (or the headless backend) first and confirm with
`lsof` as in Step 3. The headless entrypoint is
`npx --yes t3@latest serve --host 127.0.0.1`; **not yet verified** - the CLI
entrypoint check is still unchecked in `TODO/TODO.md` (Phase 5), so treat that
command as unconfirmed until it is run.

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
