# Setup

Setup and command reference for this project.

## Day-to-day

Start and stop the whole stack with `./start.sh` and `./stop.sh` ([QUICK-SETUP.md](QUICK-SETUP.md)
for the short version, "Step 5" below for the mechanics). Always-on requires
power, `caffeinate -dims`, Remote Login, and Wake for network access. `start.sh`
starts `caffeinate` for you but cannot flip Wake for network access - enable it
once in System Settings and verify `pmset -g | grep womp` shows `1`. With those
set, locking the screen and closing the lid survive as long as the Mac stays on power.

## Step 1 - CLIProxyAPI (Docker)

Prereq: Docker Desktop running (`docker version`, `docker compose version`).

```bash
umask 077
cp cliproxy/example.config.yaml cliproxy/config.yaml
mkdir -p cliproxy/auth
chmod 600 cliproxy/config.yaml
chmod 700 cliproxy/auth
openssl rand -hex 32                      # generate a key, paste into config.yaml api-keys
```


Set the KEY var to your shell:

```bash
KEY=$(grep -oE '[0-9a-f]{64}' cliproxy/config.yaml | head -1)
```

Codex OAuth login (opens a URL for the host browser, callback -> 127.0.0.1:1455):

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

The image is pinned by digest in `docker-compose.yml` rather than by `latest` or a version tag, since tags are mutable upstream and a silent pull could change routing behavior. Check the running build with `docker exec cliproxyapi ./CLIProxyAPI --version`. To move, pull the new image, re-verify `/v1/models` and effort, then update the digest and `TOOL-VERSIONS.md` together.

Models are exposed under two sets of aliases (`oauth-model-alias`), and the raw upstream ids no longer route:

- **Friendly names** - `GPT-5.6 Sol`, `GPT-5.6 Luna`, `GPT 5.5`, `GPT 5.4 mini`. Required by the `ANTHROPIC_DEFAULT_*_MODEL` role mappings in `claudex`, and the only labels that clearly show which model is actually serving you.
- **Claude slugs** - `claude-fable-5`, `claude-opus-5`, `claude-sonnet-5`, `claude-haiku-4-5` and friends, each pointing at the same upstream model as its friendly counterpart. These exist only so T3 will pass reasoning effort. See Step 3.

One upstream id can carry many aliases and they all coexist - `/v1/models` lists all 18. Use the friendly names from the CLI and the Claude slugs from T3.

Export the key for later steps (Claude Code / T3):

```bash
export CLIPROXY_LOCAL_API_KEY=<KEY>       # keep out of the repo
```

Notes:
- `config.yaml` and `cliproxy/auth/` are gitignored (key + OAuth creds). Never commit them. Keep `.env`, `config.yaml`, and auth files mode `600`, and auth directories mode `700`; `start.sh`, `cliproxy/start.sh`, and `cliproxy/login.sh` enforce this on future runs. The alias/effort setup itself *is* in git - `example.config.yaml` is identical to `config.yaml` apart from the placeholder key and a leading comment, so a lost `config.yaml` is one `cp` away from working. The local API key is regenerable in seconds (`openssl rand -hex 32`). Only the Codex OAuth credentials under `auth/` need a re-login to replace. Keep `example.config.yaml` in sync whenever `config.yaml` changes.
- **Aliases replace the upstream id, but many aliases can share one id.** After aliasing, the raw id returns `unknown provider`. Unaliased models keep their own ids. Keep `oauth-model-alias` in sync with `ANTHROPIC_DEFAULT_*_MODEL` in `../claudex`, or role lookups fail with a `502 unknown provider` that Claude Code retries as if it were transient. `customModels` in `~/.t3/userdata/settings.json` does **not** need to match - T3 lists built-in Claude models regardless, and custom entries there are actively harmful (Step 3).
- **`config.yaml` edits need a container restart.** The file is a read-only bind mount (`./config.yaml:/CLIProxyAPI/config.yaml:ro`), and the process reads it at startup. Run `./cliproxy/stop.sh` then `./cliproxy/start.sh` (`docker compose down`, then `up -d` plus the listener poll). `start.sh` on its own does not recreate an already-running container, so the old alias table stays live.
- **An alias differing only by case is ignored, with no warning.** `gpt-5.6-luna` -> `GPT-5.6-Luna` is a no-op with nothing logged and the original left in place. `GPT-5.6 Luna` works. Every alias must differ by a real character, which is why `GPT 5.5` carries a space.
- **`payload.default` effort is a no-op here.** It fills `reasoning.effort` only when the client omits it, but the `/v1/messages` -> codex translation always derives a level first. With `debug: true` on, a request with no thinking field arrives as `level=medium`, and Luna logs `medium` despite its `high` baseline. Effort is controlled by the client (`/effort`, per-agent frontmatter), not the proxy. Do not switch to `override` - it force-replaces client values and would break per-agent effort.
- **To inspect applied effort**, uncomment `debug` / `logging-to-file` / `request-log` in `config.yaml` and restart. Each call writes `cliproxy/auth/logs/v1-messages-*.log` containing both the incoming Claude request and the translated upstream codex body:

  ```bash
  for g in $(ls -t cliproxy/auth/logs/v1-messages-*.log | grep -v count_tokens | head -3); do
    echo "== $(basename $g)"
    grep -oE '"model":"[^"]*"' "$g" | head -2 | tr '\n' ' '; echo
    grep -oE '"reasoning":\{"effort":"[a-z]*"' "$g" | head -1
  done
  ```

  First model is what the client asked for, second is what actually ran. Turn logging back off when done - these files hold full request bodies, including whole conversations. Background calls Claude Code makes on its own (session titles) send no thinking field and land at `medium`. That's normal and not a sign effort failed.
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
alias claudex="$HOME/GitHub/CodeLaunch/claudex"

# Option B: put the repo dir on PATH
export PATH="$HOME/GitHub/CodeLaunch:$PATH"

# Option C: symlink into a dir already on PATH (no zshrc edit)
#   ln -sfn "$HOME/GitHub/CodeLaunch/claudex" ~/.local/bin/claudex
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
- `/effort` - levels are selectable and do apply. `ANTHROPIC_DEFAULT_*_SUPPORTED_CAPABILITIES` in the wrapper is what tells Claude Code these custom model names accept effort. Without it the flag is ignored. `claudex --model haiku --effort low` arrives upstream as `reasoning.effort: low`, and `--effort max` arrives as `xhigh`. There is no proxy-side backstop - `payload.default` is a no-op.

Prove routing from the proxy side while testing:

```bash
docker compose -f cliproxy/docker-compose.yml logs -f
```

Delegate once to each agent and confirm the child requests resolve to Luna /
GPT-5.5 / GPT-5.4 mini in the logs (not just the agent's self-report).

## Step 3 - T3 Code

Install the desktop app and confirm the CLI entrypoint:

```bash
brew install --cask t3-code             # stable; nightly channel: t3-code@nightly
npx --yes t3@$T3_CHANNEL --version      # channel must match the cask you installed
```

The app keeps the old `T3 Code (Alpha)` name internally as
`legacyUserDataDirName`, so it still shows up as a userdata directory under that
name. The cask has `auto_updates` on, so re-check the version and backend port
after each update.

**`T3_CHANNEL` must match the installed desktop app - this is enforced, not
advisory.** The CLI and the desktop backend share the `~/.t3` store and the CLI
runs schema migrations against it, so a mismatch can migrate the store to a
schema the other side cannot read.

`t3-pair.sh` reads `T3_CHANNEL` from `.env` (`latest` | `nightly`, default
`latest`), uses it for every `npx t3@<channel>` call, and **refuses to run on a
mismatch**:

```
REFUSING: T3_CHANNEL=latest but the desktop app is 'nightly'.
  app:  /Applications/T3 Code (Nightly).app
  Fix: set T3_CHANNEL=nightly in .env, or install the latest cask.
```

The channel is read from the app's `CFBundleShortVersionString`
(`0.0.29-nightly.*` -> nightly), not its bundle name, so a renamed `.app` is
still classified correctly. Detection prefers the app currently listening on
`T3_PORT` - the backend the CLI will actually migrate against - and falls back
to scanning `/Applications` and `~/Applications` when nothing is up. With no
desktop app installed there is nothing to match, and `T3_CHANNEL` simply selects
the headless backend's channel. Escape hatch, which warns loudly:
`T3_CHANNEL_SKIP_CHECK=1`.

`start.sh` runs the same guard as `./t3-pair.sh --check-only` in its prereq step
- before Docker, the proxy, or the tunnel start - so a mismatch fails in a
second rather than after a full bring-up. `--check-only` starts no backend and
mints no token.

`stop.sh` does not check the channel. Teardown has to work even when the config
is wrong, and since it never invokes the CLI there are no migrations to guard.
It reads the desktop app's bundle name back out of the running process and is
correct regardless of `T3_CHANNEL`.

npm carries both dist-tags (`npm view t3 dist-tags`): `latest` is `0.0.28` and
`nightly` is `0.0.29-nightly.*`. `.env.example` ships `latest` because a fresh
setup should use the stable channel. Set `T3_CHANNEL=nightly` in `.env` if
you're running the nightly cask (`t3-code@nightly`).

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

Two things this gets right, both of which fail with no error message otherwise:

- **The path must be absolute.** T3 spawns the binary directly, with no shell,
  so `~` is never expanded and `~/.local/bin/claudex` fails with
  `spawn ... ENOENT`. Bare `claude` works only because T3 has its own lookup for
  the default name. A custom name gets no such treatment.
- **Claude HOME must stay empty.** The field is inert either way - the wrapper's
  `exec env CLAUDE_CONFIG_DIR=...` overrides whatever T3 puts in the child
  environment - so filling it in can only mislead. On `0.0.29-nightly`,
  `makeClaudeEnvironment` returns the base environment untouched when the field
  is blank and otherwise sets `CLAUDE_CONFIG_DIR` to the resolved path. It never
  sets `HOME`, despite the app's description ("Custom HOME used when running this
  Claude instance"). On 0.0.28 the field set `HOME` instead, which would have made
  the wrapper compute `CLAUDE_CONFIG_DIR="$HOME/.claudex"` = `~/.claudex/.claudex`.
  Re-check after a cask update in case it changes again.

No environment variables go in T3. `claudex` supplies the base URL, key, and
model mappings, so the proxy key never enters T3's secret store and the mapping
has one source of truth. T3 passes the picked model as a `--model` launch
argument, which overrides the wrapper's `ANTHROPIC_MODEL=opus`, so the model
picker still works.

**T3's environment fields do not just go unused here - they are overridden.**
The wrapper ends in `exec env -u ANTHROPIC_API_KEY VAR=... "$CLAUDE_BIN" "$@"`.
Those are literal assignments on the `env` command line, so they win over
anything T3 exports into the child. Setting `ANTHROPIC_BASE_URL` or any
`ANTHROPIC_DEFAULT_*` in T3 has no effect at all, and nothing logs to say so.
The wrapper is the only place those values can be changed. `ANTHROPIC_API_KEY`
is explicitly removed with `env -u`, so an inherited key cannot leak in either.
Three variables are read from the environment on purpose, before the `exec`:

- `CLIPROXY_LOCAL_API_KEY` - overrides the key scraped from `config.yaml`.
- `CLAUDE_BIN` - overrides which `claude` binary is launched.
- `HOME` - the wrapper computes `CLAUDE_CONFIG_DIR="$HOME/.claudex"` from it, so
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
literal placeholder `/Users/<username>/.local/bin/claudex`. Left as-is, T3 fails
with `spawn ... ENOENT` for the absolute-path reason above. Replace it with the
real path.

`example.client-settings.json` carries picker state rather than provider config:
favorites for `claudeAgent` and `claudex` on `claude-fable-5` and
`claude-opus-5`, plus `providerModelPreferences.claudex.hiddenModels`, which
hides `claude-opus-4-8`, `claude-opus-4-7`, `claude-opus-4-6`, `claude-opus-4-5`
and `claude-sonnet-4-6` from the claudex picker.

The Opus 5 row needs Claude Code >= 2.1.219; below that T3 filters it out of the
picker entirely and shows an upgrade message instead.

`claude-sonnet-5` stays **visible**: it is the Sonnet route to GPT-5.5, and it is
also `DEFAULT_MODEL_BY_PROVIDER[claudeAgent]`, so a fresh claudex thread lands on
it. `config.yaml` aliases both `claude-sonnet-5` and `claude-sonnet-5[1m]` - the
latter is required because that row carries a `contextWindow` selector (200k
default / 1m) and picking 1M makes T3 send the id with `[1m]` appended. Without
the second alias, that selection returns `502 unknown provider`, which Claude Code
retries as if it were transient.

`claude-opus-5` is the Opus row to use, and the other four are hidden. It is the
only Opus slug that is both exempt from the `xhigh` -> `max` rewrite below *and*
carries a `contextWindow` selector (200k/1m, defaulting to **1M**), so it
strictly supersedes them:

- `claude-opus-4-8` matches it on effort but has no `contextWindow` selector, so
  it is capped at 200k. It was the favorite before Opus 5 shipped; now it is a
  strictly worse duplicate of the same upstream model, which is exactly the kind
  of near-identical second row that leads to picking the weaker one by accident.
- `claude-opus-4-7` and `claude-opus-4-5` are plain duplicate aliases of Luna, so
  hiding them only removes clutter.
- `claude-opus-4-6` was previously the only 1M-context route to Luna in T3 and
  hiding it cost that. Opus 5 defaults to 1M, so the tradeoff is gone.

Because that default is 1M, the **first** message of any Opus 5 thread sends
`claude-opus-5[1m]`, not `claude-opus-5`. Both are aliased in `config.yaml`;
dropping the `[1m]` one breaks the row on message one with `502 unknown provider`.

`claude-sonnet-4-6` is the last hidden row. It is still aliased to GPT-5.5 and
works, but `claude-sonnet-5` supersedes it: 4.6 is the one slug where
`normalizeClaudeCliEffort` rewrites `max` -> `high`, so its top effort level is
unreachable with no warning. Two identical Sonnet rows with different effort
ceilings is a trap, so the weaker one is hidden.

Drop any of these from `hiddenModels` to make them pickable again.

### Reasoning effort in T3: pick the Claude-named models

**T3 drops effort for custom models with no warning.** Its `claudeAgent` driver only
passes `effort` to the Agent SDK for built-in Claude model slugs. Custom models
resolve to `DEFAULT_CLAUDE_MODEL_CAPABILITIES`, an empty descriptor list, so
`resolveClaudeEffort` returns undefined and the reasoning selection never leaves
T3. No proxy setting can recover it. This is why a thread on `GPT-5.6 Luna`
always ran at the default no matter what the reasoning control said.

The fix is the second alias block in `config.yaml`: the upstream models are also
aliased to built-in Claude slugs, so selecting one makes T3 attach effort.

- In the model picker choose the **Claude-named** entries, not the `GPT ...`
  ones. `Claude Opus 5` -> Luna, `Claude Fable 5` -> Sol,
  `Claude Sonnet 5` -> GPT-5.5, `Claude Haiku 4.5` -> 5.4 mini.
- **Empty `customModels`** for the claudex instance. The `GPT ...` entries are
  the only way to pick a model that ignores effort, and they look identical to
  the working ones in the UI. Removing them from T3 costs nothing -
  `claudex --model 'GPT-5.6 Sol'` still works from a terminal.
- **T3 remaps effort before sending it.** The selector offers `low`, `medium`,
  `high`, `xhigh`, `max`, `ultracode` and `ultrathink`, but
  `normalizeClaudeCliEffort` rewrites the selection on the way out (both the CLI
  and SDK paths, via `getEffectiveClaudeAgentEffort`): `ultrathink` sends nothing
  at all, `ultracode` -> `xhigh`, and `xhigh` -> `max` for every model except
  `claude-fable-5`, `claude-opus-5`, `claude-opus-4-8` and `claude-sonnet-5`.
  `low`, `medium` and `high` pass through unchanged, and `claude-sonnet-5`
  additionally passes both
  `xhigh` and `max` through untouched - it is exempt from the `xhigh` -> `max`
  rewrite and from the `max` -> `high` rewrite.
- **`max` downgrades on `claude-sonnet-4-6` only.** `max` -> `high` there, so
  picking "Max" on that row actually sends `high`. `xhigh` maps up to `max`.
  That row is hidden by default for this reason.
- **Do not pick "Max" on the Sonnet 5 row - it fails.** Upstream `gpt-5.5`
  supports `none, low, medium, high, xhigh` and has **no** `max`. On
  `claude-sonnet-4-6` T3's `max` -> `high` rewrite accidentally hid that.
  `claude-sonnet-5` has no such rewrite, so selecting "Max" sends a literal `max`
  to a model that does not advertise it. The request errors rather than falling
  back to a default (the `payload.default` effort only fills an *omitted*
  level, and "Max" sends one explicitly, so there is no backstop). **`xhigh` is
  the top usable level on the Sonnet 5 row.** T3 gives no way to remove `max`
  from the picker - the effort list is baked into the built-in slug's descriptor
  and `hiddenModels` only hides whole rows - so this is a discipline constraint,
  not something the config can enforce.
- Haiku 4.5 exposes only a thinking toggle in T3, so 5.4 mini gets no effort
  control through the app. Use the CLI for that.
- Fast Mode on the Opus entries is untested against the proxy. Leave it off.

**The model will lie about its identity under these slugs.** Claude Code's
system prompt asserts it is Claude and the model id now agrees, so asking
"what model are you?" returns a confident wrong answer - a thread on
`claude-opus-5` is really GPT-5.6 Luna. Anything keyed on model identity
(the `claude-api` skill, model-conditional agent frontmatter) will misfire
toward Claude behaviour. The proxy logs are the only ground truth. This is the
unavoidable cost of getting effort through T3. The CLI keeps honest labels.

Verify a T3 thread end to end by enabling request logging (Step 1 notes), then
sending one message at low reasoning. Expect the incoming model to be the Claude
slug, the upstream model to be the GPT id, and `reasoning.effort` to be `low`.

Verify, with the proxy up:

- Native thread: Fable/Opus/Sonnet/Haiku keep their normal Claude mappings.
- Claudex thread: `/status` shows `~/.claudex` and base URL `127.0.0.1:8317`, and
  `/agents` lists the four GPT-named agents.
- Claudex thread on a Claude-named model with reasoning set to low: the request
  log shows `reasoning.effort: low` against the GPT upstream id.
- Confirm routing in `docker compose -f cliproxy/docker-compose.yml logs -f`,
  not the client's self-report.

Confirm the backend port and that it is loopback-only:

```bash
lsof -nP -iTCP -sTCP:LISTEN | grep -i t3
```

Expect `127.0.0.1:3773`, matching the documented default, with Desktop
Network access off. Re-check after a cask auto-update. If this ever shows
`0.0.0.0`, stop and turn Network access back off before running the tunnel.

Headless fallback, if Desktop's managed backend does not work out:

```bash
npx --yes t3@$T3_CHANNEL serve --host 127.0.0.1
```

Run only one backend at a time. Pairing tokens and sessions are managed with
`t3 auth pairing` and `t3 auth session`. Treat a pairing URL as a password.

## Step 4 - Cloudflare tunnel + Access

The Access app + policy, tunnel, and proxied CNAME can all be created through the
Cloudflare REST API with a scoped token instead of `cloudflared tunnel login`.
That means **no `~/.cloudflared/cert.pem` needs to exist** - the account-wide,
~10-year "manage all tunnels" credential is never written. The tunnel is
locally-managed (`config_src: local`), so `cloudflared tunnel run` works from
`config.yml` and the `<UUID>.json` credentials file alone. Unauthenticated
requests get a 302 to the Access login with the app's `aud`. Real IDs and
secrets live only on the host and in Cloudflare, never in git.

The API path, for reference (token was a scoped, short-lived custom token with
`Access: Apps and Policies` edit, `Access: Organizations, IdPs, and Groups` edit,
`Cloudflare Tunnel` edit, and zone `DNS` edit):

```bash
. ./scripts/env.sh
codelaunch_load_env T3_HOSTNAME T3_PORT TUNNEL_NAME ACCESS_EMAIL CLOUDFLARE_TEAM
CF=$(tr -d '[:space:]' < ~/.ssh/CloudFlare_API_KEY/cloudflare-tunnel-api.key)
H="Authorization: Bearer $CF"

# account_id from the zone, plus an org + IdP sanity check
curl -s "https://api.cloudflare.com/client/v4/zones?name=$(echo $T3_HOSTNAME | cut -d. -f2-)" -H "$H"
curl -s "https://api.cloudflare.com/client/v4/accounts/$ACCT/access/organizations" -H "$H"

# Access first: reusable policy, then app (auto_redirect to the one IdP)
curl -s -X POST ".../accounts/$ACCT/access/policies" -H "$H" \
  --data '{"name":"...","decision":"allow","include":[{"email":{"email":"'$ACCESS_EMAIL'"}}],"session_duration":"1h"}'
curl -s -X POST ".../accounts/$ACCT/access/apps" -H "$H" \
  --data '{"name":"T3 Code","type":"self_hosted","domain":"'$T3_HOSTNAME'","session_duration":"1h","auto_redirect_to_identity":true,"allowed_idps":["<idp>"],"policies":[{"id":"<policy>","precedence":1}]}'

# Tunnel: generate secret, create local tunnel, hand-write credentials JSON
SECRET=$(openssl rand -base64 32)
curl -s -X POST ".../accounts/$ACCT/cfd_tunnel" -H "$H" \
  --data '{"name":"'$TUNNEL_NAME'","config_src":"local","tunnel_secret":"'$SECRET'"}'
#  -> ~/.cloudflared/<UUID>.json = {"AccountTag","TunnelSecret":SECRET,"TunnelID"}

# DNS last (equivalent to `route dns`, no cert.pem needed)
curl -s -X POST ".../zones/$ZONE/dns_records" -H "$H" \
  --data '{"type":"CNAME","name":"code","content":"<UUID>.cfargotunnel.com","proxied":true,"ttl":1}'
```

Real values live in `.env` (gitignored), not in this file:

```bash
umask 077
cp .env.example .env      # then fill in, and load for the commands below
chmod 600 .env
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
at all. Expect an absence from the zone list rather than an outright error.

**A Cloudflare Zero Trust organization exists.** One-time setup in the
dashboard, producing a team domain `<team>.cloudflareaccess.com`. The Access
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
. ./scripts/env.sh
codelaunch_load_env T3_HOSTNAME T3_PORT TUNNEL_NAME ACCESS_EMAIL CLOUDFLARE_TEAM
```

**T3 must already be serving on `$T3_PORT`.** `cloudflared tunnel run` connects
to the edge whether or not anything is listening at the origin, so a missing
backend is not a tunnel failure. Access sits in front, so the failure only shows
up after authenticating: expect Cloudflare error 1033 when no tunnel is running
or the hostname is misrouted, and a 502 only once the tunnel is up but the origin
port is dead. Start Desktop (or the headless backend) first and confirm with
`lsof` as in Step 3. The headless entrypoint is
`npx --yes t3@$T3_CHANNEL serve --host 127.0.0.1`. Test that command on its own before
relying on it.

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

**Turn on 2FA for the Cloudflare account.** With the built-in **Cloudflare**
identity provider as the org's only IdP, account 2FA is the MFA layer - there is
no separate "Independent MFA" toggle doing it for you. The AMR-based MFA policy
rule only supports Okta/Entra/OIDC/SAML, not the Cloudflare IdP, Google, or OTP,
and free-tier Independent MFA availability is unconfirmed. The app pins
`allowed_idps` to that one IdP with `auto_redirect_to_identity: true`, so there
is no IdP chooser to leak other login methods. From off-network/VPN, a
Google-account login is refused since the policy pins the exact email, and only
the pinned Cloudflare account with 2FA passes.

The Cloudflare-IdP consent screen ("... wants to connect to Cloudflare") took its
label from the IdP `name`, which was empty and showed as "Unknown app". Setting
the IdP `name` to `T3 Code` (`PUT .../access/identity_providers/<id>`, preserving
`type: cloudflare` and `config.restrict_to_account_members: true`) is the lever.
The Access app `name` and org name do not drive it. Undocumented, so re-verify
after Cloudflare changes.

### 4B. Tunnel

```bash
cloudflared tunnel login
cloudflared tunnel create "$TUNNEL_NAME"
cloudflared tunnel list                   # note the UUID
```

Write `~/.cloudflared/config.yml` (outside the repo, credentials JSON stays
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
start, and it stops any other hostname from reaching the origin.

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
conflicts with the on-demand orchestration this setup uses and would leave
ingress up whenever the Mac is awake.

Verify in this order, from a private window:

- `https://$T3_HOSTNAME` is blocked by Access until the exact email plus MFA.
- A different email is refused.
- After Access passes, a browser with no T3 device session still cannot use the
  backend. This is the layer that matters if Access is ever misconfigured.
- A live agent response streams end to end (WebSocket through the tunnel).
- `lsof -nP -iTCP -sTCP:LISTEN` shows T3 on loopback only. With the default
  `T3_BIND=loopback` a `0.0.0.0` listener means something is wrong; under
  `T3_BIND=all` the wildcard bind is expected and `t3-pair.sh` asserts it (see
  4E).

Revoke the test session afterward with `t3 auth session`.

### 4D. T3 pairing (app-layer gate, separate from Access)

Passing Cloudflare Access is not enough: T3 requires its own one-time pairing
credential before a browser can drive the backend, so a remote browser lands on
"Pair with this environment". This is a second, independent layer - even a
misconfigured Access policy leaves the backend unusable without a T3 session.
Leave Desktop's **Network access** on "Limited to this machine." The tunnel never
needs it (it connects over loopback), and CodeLaunch cannot guard that toggle -
it belongs to the app, not to the backend the scripts manage. When you do want
LAN or VPN reach, use `T3_BIND=all` (4E) instead: it applies to the headless
backend, and `t3-pair.sh` verifies the resulting bind on every run.

The desktop `.app` is only a GUI - the backend is the same `t3` server it spawns,
runnable headless with `t3 serve`. Pairing tokens are issued by the CLI against
the shared `~/.t3` auth store (default `T3CODE_HOME`), so they validate whichever
single backend is listening. `./t3-pair.sh` reuses or starts that backend, verifies
its bind matches `T3_BIND`, and prints the code, URLs, expiration, and optional
terminal QR. `jq` is required for
that structured output; install it with `brew install jq`. `qrencode` is
recommended but optional (`brew install qrencode`); pairing still succeeds
without it or if QR rendering fails. Newly started headless backends write to the
private `$HOME/.codelaunch/run/t3-serve.log` file; an already-running process
keeps its current log until it is restarted.

```bash
./t3-pair.sh            # 15m token (default)
./t3-pair.sh 5m         # custom TTL
```

Open the printed URL in the already-Access-authenticated browser (or paste the
token into the pairing field). It is one-time and short-lived, so treat it like
a password. `t3 auth pairing list|revoke` and `t3 auth session list|revoke`
manage outstanding tokens and sessions. The headless-start path has not been
tested while the desktop app owns the port, so test it with the app closed.

### 4E. Direct LAN/VPN pairing - required for the mobile app

The mobile app cannot complete Cloudflare Access, so it must connect directly
over a trusted LAN or VPN. In `.env`:

```bash
T3_BIND=all
T3_CHANNEL=latest
```

`T3_BIND=all` starts the backend on `0.0.0.0`. The Cloudflare tunnel still uses
loopback, while `t3-pair.sh` also prints direct URLs for current LAN and VPN
addresses.

In the app, choose **Add Environment** and enter a printed host with the scheme,
for example `http://10.0.0.7:3773`, plus the printed code. A bare host may be
rewritten to `https://`.

Direct connections bypass Cloudflare Access. The pairing code is the only gate,
so enable this only on a network you trust. `t3-pair.sh` verifies the live bind
matches `T3_BIND` and asks you to restart a backend started with the other mode.

## Step 5 - Orchestration (start.sh / stop.sh)

`./start.sh [ttl]` brings the stack up in order, each step gated on a health
check and idempotent so a live stack short-circuits to reuse:

1. **prereqs** - `.env` is parsed by `scripts/env.sh`, which accepts only the
   expected variables and never executes it as shell code. `docker`, `cloudflared`,
   `claude`, `claudex`, `npx`, and required `jq` are checked on PATH (all missing
   reported at once); `qrencode` remains optional for terminal QR rendering.
2. **caffeinate** - warns (not fails) off AC power, and starts `caffeinate -dims`
   if none is running. It cannot enable Wake for network access - that stays a
   manual `pmset`/System Settings step (`pmset -g | grep womp` must read `1`).
3. **Docker** - reuse if `docker info` succeeds, else run `docker desktop start`
   (native Desktop CLI, with existence probed via `docker desktop --help` since
   `status` can exit non-zero merely because Desktop is stopped) with an
   `open -g -j -a Docker` fallback, then poll `docker info` up to 120s.
4. **Codex token** - uses the newest `cliproxy/auth/codex-*.json`, valid while
   now is before the ISO-8601 `expired` field (compared tz-aware, offset
   preserved). If expired or missing and stdin is a TTY, it runs
   `./cliproxy/login.sh` (browser, callback `127.0.0.1:1455`) and re-checks. On a
   non-TTY it fails and tells you to run login on the host.
5. **cliproxy** - `./cliproxy/start.sh`, then an authenticated
   `curl /v1/models` with the key grepped from `config.yaml`. A rejected key
   fails loudly.
6. **backend** - `./t3-pair.sh --ensure-only` reuses or starts the T3 backend and
   verifies its live bind matches `T3_BIND`.
7. **tunnel** - reuse the named `$TUNNEL_NAME` process if it is already up, else
   launch it
   to `$HOME/.codelaunch/run/cloudflared-t3.log` and poll for `Registered tunnel
   connection` (up to 30s, printing `tail -20` on timeout). Reused processes keep
   their existing log destination until restarted.
8. **pairing token** - `./t3-pair.sh [ttl]` rechecks the backend and mints the
   one-time token only after the tunnel is ready.

`./stop.sh` reverses it and leaves **Docker Desktop, the Docker daemon, native
Claude Code, and `caffeinate -dims`** running on purpose:

- **tunnel** - SIGTERM the named `$TUNNEL_NAME` process, wait up to 35s for its
  grace period, then signal it again if needed. Other cloudflared connectors are
  left alone.
- **T3 backend** - the PID listening on `$T3_PORT`. If its command path contains
  a desktop app bundle, its app name is passed to AppleScript as an argument for
  a graceful quit; otherwise the headless `t3 serve` gets SIGTERM then SIGKILL
  as a last resort.
- **claudex sessions** - matched by the literal `CLAUDE_CONFIG_DIR=$HOME/.claudex`
  in the process **environment** (`ps eww` appends env vars). Native Claude Code
  lacks that marker, so it is never touched. SIGTERM only.
- **cliproxy** - `./cliproxy/stop.sh` (`docker compose down`), skipped with a
  note if docker is unreachable.
- **caffeinate** - intentionally left running so a remote stop does not release
  the sleep assertion before SSH can start the stack again. `start.sh` reuses it.

Every kill is guarded with `|| true` so re-runs are clean no-ops.
