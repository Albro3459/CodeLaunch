# Agent setup TODO

Research date: 2026-07-20
Target host: ARM macOS 26
Target public hostname: `code.<domain>`

## Outcome

Build a local agent host with:

- Claude Code running GPT-5.6 Sol through CLIProxyAPI.
- Separate native-Claude and Claudex configuration directories, with GPT-named Claudex subagents resolving through Claude Code's supported model roles.
- A native Claude Code provider for Claude Fable 5, Opus 4.8, Sonnet 5, and Haiku.
- T3 Code Desktop for local use and a T3 HTTP/WebSocket backend for remote use.
- Cloudflare Access, Tunnel, and DNS in front of the T3 backend.

## Architecture decision

Use two Claude Code provider profiles in T3 Code:

1. **Claude via CLIProxyAPI**: Codex subscription authenticated through CLIProxyAPI, with Claude Code roles remapped as Fable -> GPT-5.6 Sol, Opus -> GPT-5.6 Luna, Sonnet -> GPT-5.5, and Haiku -> GPT-5.4 mini.
2. **Claude Native**: existing Claude subscription login with the normal Fable, Opus, Sonnet, and Haiku mappings.

Model-ID verification (2026-07-20), all confirmed against OpenAI's model docs:

- `gpt-5.6-sol` and `gpt-5.6-luna`: GPT-5.6 supports `none, low, medium, high, xhigh, max`.
- `gpt-5.5` (snapshot `gpt-5.5-2026-04-23`): supports `none, low, medium, high, xhigh`; no `max`.
- `gpt-5.4-mini` (snapshot `gpt-5.4-mini-2026-03-17`): supports `none, low, medium, high, xhigh`; no `max`.

These are provider-side mappings only: each Claude role is a label CLIProxyAPI routes to the GPT model above. The role names carry no capability meaning here.

Both profiles use the same installed `claude` executable but separate configuration directories. Native Claude keeps the default `~/.claude`. Claudex sets `CLAUDE_CONFIG_DIR=~/.claudex`, which is Claude Code's supported configuration-directory override. A second Claude Code installation and a fake alternate macOS `HOME` are not needed.

CLIProxyAPI supports both Codex and Claude OAuth providers. This plan only requires Codex OAuth in CLIProxyAPI because the normal Claude Code profile is already authenticated directly to the Claude subscription. Keeping the subscriptions in separate profiles makes routing and credential ownership obvious:

- **Implement first:** an isolated `~/.claudex` profile with provider-specific instructions and GPT-named agents.
- **Native profile:** `fable`, `opus`, `sonnet`, and `haiku` retain their normal Claude meanings.
- **CLIProxyAPI profile:** the same aliases resolve to Sol, Luna, GPT-5.5, and GPT-5.4 mini respectively.
- **Not required for this plan:** Claude OAuth inside CLIProxyAPI or a mixed GPT/Claude subagent tree. CLIProxyAPI may make that experiment possible, but it needs a separate live compatibility test and is outside the requested two-session design.

The Claudex profile names agents after their actual GPT destinations so delegation is unambiguous: `gpt-5-6-luna`, `gpt-5-5`, and `gpt-5-4-mini`. Claude Code agent names cannot contain periods, so hyphens replace the periods. Their `model` frontmatter uses the supported Claude roles `opus`, `sonnet`, and `haiku`; the proxy environment maps those roles to the actual GPT model IDs. Keep all CLIProxyAPI variables scoped to the CLIProxyAPI T3 provider or the `claudex` invocation; never put them in native `~/.claude/settings.json`.

Do not expose CLIProxyAPI through Cloudflare. Explicitly bind it to `127.0.0.1`; its documented default host setting otherwise listens on all interfaces. Configure a strong local API key even though only T3 is exposed publicly. Expose only T3 Code through the tunnel.

The Codex CLI is not required for the proxy-backed Claude Code profile. `cliproxyapi --codex-login` performs and stores its own ChatGPT/Codex OAuth login. Install the standalone Codex CLI only if T3 should also offer its native Codex provider, or if the optional official Codex plugin for native Claude Code will be used.

### Session layout

```text
Native Claude session
  same claude binary
  default ~/.claude configuration and existing Claude subscription login
  no ANTHROPIC_BASE_URL override
  Fable 5 / Opus 4.8 / Sonnet 5 / Haiku

Codex-model session in Claude Code harness
  same claude binary
  CLAUDE_CONFIG_DIR=~/.claudex
  Claudex-specific CLAUDE.md, settings, agents, and session state
  ANTHROPIC_BASE_URL=http://127.0.0.1:8317
  CLIProxyAPI-owned ChatGPT/Codex subscription login
  fable -> GPT-5.6 Sol
  opus -> GPT-5.6 Luna
  sonnet -> GPT-5.5
  haiku -> GPT-5.4 mini
```

## Current machine findings

- [x] Claude Code is installed at `~/.local/bin/claude` and reports version `2.1.215`.
- [x] The normal interactive shell does not contain a Codex CLI. The Codex desktop execution environment can see an app-bundled executable at `/Applications/ChatGPT.app/Contents/Resources/codex`, but that is not a user-installed CLI and does not appear in the user's `which -a codex` output.
- [x] Node.js, npm, and npx are installed through `fnm`: Node `v24.18.0` and npm `11.16.0`.
- [ ] Ensure `fnm` activation is available in every shell or service that will run `npx t3`. The non-interactive execution shell used during research did not inherit the user's `fnm` multishell path, which caused the earlier false "Node not installed" finding.
- [ ] Decide whether to install the standalone Codex CLI. It is optional for the proxy-backed Claude profile, but required for T3's native Codex provider and the optional official Codex plugin.
- [x] Install T3 Code. Desktop is installed and running; its backend listens on `127.0.0.1:3773`. The `t3` CLI is still not on `PATH` — use `npx t3@latest` for CLI work.
- [x] Install `cloudflared`. Present at `/opt/homebrew/bin/cloudflared`.
- [x] Install Docker Desktop and confirm `docker` and `docker compose` are available. `docker` at `/usr/local/bin/docker`; the `cliproxyapi` container runs under compose.

## Phase 1: prerequisites

- [x] Confirm the `fnm`-managed Node.js release satisfies T3's documented server requirement: `^22.16 || ^23.11 || >=24.10`. Node `v24.18.0` satisfies it.

  ```bash
  which -a node npm npx
  node --version
  npm --version
  npx --version
  ```

- [ ] Verify a new interactive terminal initializes `fnm` and exposes Node/npm/npx before installing or serving T3.

### Optional standalone Codex CLI

Skip this subsection when the only Codex-model path will be Claude Code -> CLIProxyAPI.

- [ ] If T3's native Codex provider or the official Codex plugin is wanted, install the standalone Codex CLI using the current official installer, then authenticate with the ChatGPT subscription.

  ```bash
  curl -fsSL https://chatgpt.com/codex/install.sh | sh
  codex login
  codex login status
  ```

- [ ] If installed, confirm the standalone `codex` path is stable and configure that exact binary path in T3 if the macOS GUI does not inherit the terminal `PATH`.
- [ ] If installed, inspect the available model catalog and confirm this subscription exposes `gpt-5.6-sol`, `gpt-5.6-luna`, `gpt-5.5`, and `gpt-5.4-mini`.

  ```bash
  codex debug models
  ```

Notes:

- Official Codex authentication supports ChatGPT subscription login and API-key login. Use ChatGPT login here so usage follows the Codex subscription.
- The proxy login and standalone Codex CLI login are separate flows. The proxy does not need the CLI login.
- If the CLI is installed, the Codex CLI and IDE extension share cached login state. The current public docs do not promise that an already-running desktop app alone makes a newly installed CLI ready for T3, so explicitly verify with `codex login status`.
- `gpt-5.6-luna` and `gpt-5.4-mini` are the exact model IDs; the display names are not model IDs.

## Phase 2: CLIProxyAPI and Codex OAuth

CLIProxyAPI is third-party software, even though the supplied OpenAI employee post recommends this recipe. Pin or record the installed version, review release notes before upgrades, and expect compatibility to need retesting after Claude Code or Codex changes.

Deployment choice: run CLIProxyAPI in Docker (portable across machines and operating systems, only the proxy is containerized) with a native Homebrew install as the fallback. CLIProxyAPI is the one component that containerizes cleanly here: it is a stateless HTTP server whose only persistent state is the OAuth cache. T3, the `claude` binary, and `cloudflared` stay native on the Mac because they are tied to this host's GUI app, logins, and config-directory isolation; see Phase 5.

### 2A. Docker deployment (preferred)

- [x] Confirm Docker Desktop is installed and running.

  ```bash
  docker version
  docker compose version
  ```

- [x] Create a project directory (outside this repository) with `config.yaml` and `docker-compose.yml`. Publish only to loopback and mount the auth directory so OAuth state survives container restarts. Use a newly generated high-entropy value for `<CLIPROXY_LOCAL_API_KEY>` and never commit it.

  ```yaml
  # config.yaml
  host: "0.0.0.0"   # binds inside the container only; the published port restricts exposure to loopback
  port: 8317

  remote-management:
    allow-remote: false
    secret-key: ""

  auth-dir: "/data/.cli-proxy-api"

  api-keys:
    - "<CLIPROXY_LOCAL_API_KEY>"
  ```

  ```yaml
  # docker-compose.yml
  services:
    cliproxyapi:
      image: ghcr.io/router-for-me/cliproxyapi:latest   # confirm the exact published image name/tag before use
      restart: unless-stopped
      ports:
        - "127.0.0.1:8317:8317"   # host loopback only; never 0.0.0.0 on the host side
      volumes:
        - ./config.yaml:/app/config.yaml:ro
        - cliproxy-auth:/data/.cli-proxy-api
  volumes:
    cliproxy-auth:
  ```

  In Docker the container's `host` is set to `0.0.0.0` so the process is reachable inside the container network, and exposure is restricted by publishing to `127.0.0.1:8317` on the host. Verify the exact image name, tag, and in-container config/auth paths against current CLIProxyAPI docs before first run; pin a specific tag rather than `latest` once confirmed.

  As built (2026-07-21), this landed in `cliproxy/` **inside** this repository rather than outside it. `config.yaml`, `auth/`, and `*.log` are covered by `.gitignore` and `git ls-files cliproxy` confirms only `docker-compose.yml`, `example.config.yaml`, `login.sh`, `start.sh`, and `stop.sh` are tracked — no secret is committed. The real values also differ from the sketch above: image `eceasy/cli-proxy-api:latest`, config mounted at `/CLIProxyAPI/config.yaml`, auth bind-mounted from `./auth` to `/root/.cli-proxy-api` (a bind mount, not a named `cliproxy-auth` volume).

- [ ] Pin the image to a specific tag instead of `latest`. `eceasy/cli-proxy-api:latest` currently resolves to `v7.2.92`; pin that digest/tag so an upstream push cannot silently change routing behavior.

- [x] Authenticate the Codex subscription against the containerized proxy. The browser OAuth callback uses local port `1455`, so run the login with `--no-browser` from inside the container and complete the flow in the host browser; the mounted `cliproxy-auth` volume persists the result.

  ```bash
  docker compose run --rm -p 127.0.0.1:1455:1455 cliproxyapi --codex-login --no-browser
  ```

  This is CLIProxyAPI's own ChatGPT/Codex OAuth flow. It does not require the Codex CLI and does not reuse the native Claude Code login. Confirm exactly how the installed image expects `--codex-login` to be invoked and whether the `1455` callback must be published; adjust the command to match.

  Resolved: the working invocation is wrapped in `cliproxy/login.sh`. The image needs the explicit entrypoint and does **not** need `--no-browser`; publishing `1455` is required.

  ```bash
  docker compose run --rm -p 127.0.0.1:1455:1455 cliproxyapi \
    /CLIProxyAPI/CLIProxyAPI --codex-login
  ```

  Credential landed at `cliproxy/auth/codex-<id>-<email>-plus.json`.

- [x] Start the service and confirm the exact loopback listener.

  ```bash
  docker compose up -d
  docker compose ps
  ```

  Expected origin from the host: `http://127.0.0.1:8317`. Confirm with `lsof -nP -iTCP:8317 -sTCP:LISTEN` that only a loopback listener exists on the host. Stop and fix the compose port mapping if it publishes on a LAN address or `0.0.0.0`.

  Verified 2026-07-21: the only listener is `127.0.0.1:8317` (com.docker.backend). `cliproxy/start.sh` wraps `docker compose up -d` plus a readiness poll; `cliproxy/stop.sh` runs `docker compose down`.

### 2B. Homebrew fallback (native)

Not used. The Docker path in 2A is working, so this subsection stays unchecked as a documented fallback only.

- [ ] Install the current Homebrew formula (no tap required).

  ```bash
  brew install cliproxyapi
  cliproxyapi --help
  ```

- [ ] Before starting the service, edit the configuration file. On an Apple Silicon Homebrew installation the default path is normally `/opt/homebrew/etc/cliproxyapi.conf`; confirm it with `brew --prefix` if needed. CLIProxyAPI docs suggest keeping the real config at `~/.cli-proxy-api/config.yaml` and symlinking the Homebrew path to it; either way, edit exactly one authoritative file. Use a newly generated high-entropy value for `<CLIPROXY_LOCAL_API_KEY>` and never commit it.

  ```yaml
  host: "127.0.0.1"
  port: 8317

  remote-management:
    allow-remote: false
    secret-key: ""

  auth-dir: "~/.cli-proxy-api"

  api-keys:
    - "<CLIPROXY_LOCAL_API_KEY>"
  ```

  For the native path the explicit `127.0.0.1` host is mandatory. CLIProxyAPI documents an empty host as listening on every interface. An empty management secret disables the management API; leave remote management off.

- [ ] Authenticate CLIProxyAPI directly with the Codex subscription. The browser OAuth callback uses local port `1455`.

  ```bash
  cliproxyapi --codex-login
  ```

  Use `--no-browser` only if the normal browser callback flow cannot be used. Start the service with `brew services start cliproxyapi` and confirm the origin `http://127.0.0.1:8317`; stop and fix the configuration if it listens on a LAN address or `0.0.0.0`.

### 2C. Effort policy (per-model defaults)

CLIProxyAPI's `payload` section applies request rules per model. Use **`default`** rules, which set `reasoning.effort` only when the client omits it — this yields a per-model baseline while still letting a subagent's `effort` frontmatter or the interactive `/effort` slider win when Claude Code sends one. Do **not** use `override` (it force-replaces the client value and erases per-subagent and per-turn choices). Add this to whichever config file the deployment uses (Docker `config.yaml` or the native `.conf`).

Desired baselines: `high` for Sol and Luna, `medium` for GPT-5.5 and GPT-5.4 mini. Because the rule keys on the destination model, Luna gets `high` whether it is the main agent or a subagent, unless its subagent frontmatter sends a lower value for the sub case.

```yaml
payload:
  default:
    - models:
        - name: "gpt-5.6-sol"
          protocol: "codex"
        - name: "gpt-5.6-luna"
          protocol: "codex"
      params:
        "reasoning.effort": "high"
    - models:
        - name: "gpt-5.5"
          protocol: "codex"
        - name: "gpt-5.4-mini"
          protocol: "codex"
      params:
        "reasoning.effort": "medium"
```

- [x] Verify the exact `payload` schema (rule types `default` / `default-raw` / `override` / `override-raw`, the `models`/`name`/`protocol` shape, and the `reasoning.effort` gjson/sjson path) against the installed CLIProxyAPI version before relying on it. Schema accepted as written on `v7.2.92`.
- [x] Confirm the correct `protocol` value for how CLIProxyAPI routes these models to the Codex upstream. `codex` is correct.
- [x] Live-test the layering (raw `/v1/chat/completions`, 2026-07-21): with no client effort, `gpt-5.6-sol` reasoning tokens tracked forced `high` and sat well above forced `low`, confirming the `default` rule injects `high` and yields to an explicit client value. Still to test through Claude Code: that a subagent `effort` frontmatter overrides the default for that agent only.

**Correction — the `payload` block is inert on the path Claude Code actually uses.** The result above was measured on `/v1/chat/completions`. Claude Code speaks `/v1/messages`, and that translation always derives a `reasoning.effort` level before the `default` rule is evaluated, so there is never an omitted value for `default` to fill. Verified with `debug: true`: a request with no thinking field arrives as `level=medium`, and Luna logged `medium` despite the `high` baseline; a small thinking budget arrives as `level=low` and passes through. Effort is therefore controlled entirely by the client (Claude Code `/effort`, per-agent frontmatter, T3's effort selector), not by the proxy. The block is kept in `config.yaml` as documented intent. Do **not** "fix" this with `override` — that force-replaces client values and would break per-agent effort.

- [ ] Decide whether to delete the inert `payload` block or leave it as documentation. If per-model baselines are actually wanted, they must be set client-side (agent frontmatter / profile `effortLevel`), not in the proxy.

- [x] Put the same local API key in a private shell environment or secret store as `CLIPROXY_LOCAL_API_KEY`. Do not put it in this repository. The `claudex` wrapper reads `$CLIPROXY_LOCAL_API_KEY` first and falls back to scraping the key out of the gitignored `cliproxy/config.yaml`.
- [x] Create `~/.claudex` as the isolated Claudex configuration directory. Copy or link only the settings, skills, commands, rules, and MCP configuration that should be common. Do not copy native authentication caches or session state wholesale. Done — `~/.claudex` has its own `settings.json`, `agents/`, `skills/`, `projects/`, and `sessions/`.
- [x] Add a Claudex-specific `~/.claudex/CLAUDE.md` that lists the GPT-named subagents and their role mappings, and tells the parent to delegate using those agent names rather than Claude model names. It imports the shared `~/.claude/CLAUDE.md` for common rules.
- [ ] Reconcile the "primary model" statement. This item originally called for Sol as primary, but `~/.claudex/CLAUDE.md` names GPT-5.6 Luna (the `opus` role) as primary, the wrapper sets `ANTHROPIC_MODEL=opus`, and `~/.claudex/settings.json` sets `"model": "haiku"` with `"effortLevel": "low"`. Pick one intended default and make the three agree.
- [x] Launch a one-off Sol session from the isolated Claudex profile using the adjusted Tibo/Theo recipe and the four role mappings. Superseded by the `claudex` wrapper at `~/.local/bin/claudex` (source in `claudex/`), which applies the same `env -u ANTHROPIC_API_KEY` invocation and forwards arguments.

  ```bash
  env -u ANTHROPIC_API_KEY \
  CLAUDE_CONFIG_DIR="$HOME/.claudex" \
  ANTHROPIC_BASE_URL=http://127.0.0.1:8317 \
  ANTHROPIC_AUTH_TOKEN="$CLIPROXY_LOCAL_API_KEY" \
  ANTHROPIC_DEFAULT_FABLE_MODEL=gpt-5.6-sol \
  ANTHROPIC_DEFAULT_FABLE_MODEL_NAME='GPT-5.6 Sol' \
  ANTHROPIC_DEFAULT_FABLE_MODEL_SUPPORTED_CAPABILITIES=effort,xhigh_effort,max_effort \
  ANTHROPIC_DEFAULT_OPUS_MODEL=gpt-5.6-luna \
  ANTHROPIC_DEFAULT_OPUS_MODEL_NAME='GPT-5.6 Luna' \
  ANTHROPIC_DEFAULT_OPUS_MODEL_SUPPORTED_CAPABILITIES=effort,xhigh_effort,max_effort \
  ANTHROPIC_DEFAULT_SONNET_MODEL=gpt-5.5 \
  ANTHROPIC_DEFAULT_SONNET_MODEL_NAME='GPT-5.5' \
  ANTHROPIC_DEFAULT_SONNET_MODEL_SUPPORTED_CAPABILITIES=effort,xhigh_effort \
  ANTHROPIC_DEFAULT_HAIKU_MODEL=gpt-5.4-mini \
  ANTHROPIC_DEFAULT_HAIKU_MODEL_NAME='GPT-5.4 mini' \
  ANTHROPIC_DEFAULT_HAIKU_MODEL_SUPPORTED_CAPABILITIES=effort,xhigh_effort \
  CLAUDE_CODE_ENABLE_GATEWAY_MODEL_DISCOVERY=1 \
  CLAUDE_CODE_MAX_TOOL_USE_CONCURRENCY=3 \
  ENABLE_TOOL_SEARCH=false \
  claude --model fable
  ```

  `env -u ANTHROPIC_API_KEY` removes any inherited key instead of setting an empty string; empty-string versus unset behavior is version-dependent and not documented, so unset it explicitly. `CLAUDE_CODE_ENABLE_GATEWAY_MODEL_DISCOVERY=1` lets Claude Code read model metadata, including effort capabilities, from CLIProxyAPI's `/v1/models`, which is the gateway-path substitute for the `_SUPPORTED_CAPABILITIES` variables that a custom base URL may ignore.

- [ ] In the proxied session, run `/status`, verify `CLAUDE_CONFIG_DIR`, the base URL, and that `fable` resolves to Sol, then perform a harmless tool-call smoke test. Confirm the request appears in CLIProxyAPI logs.
- [ ] Open `/model` and confirm the friendly GPT names appear for all four remapped roles.
- [ ] Use `/effort low`, `/effort medium`, `/effort high`, and `/effort xhigh` in small prompts. Also test `/effort max` on Sol and Luna only. Confirm CLIProxyAPI logs report the requested model and effort.
- [ ] Record `cliproxyapi`'s installed version and the exact GPT model IDs returned by a live request.

### 2D. Codex OAuth re-authentication

CLIProxyAPI's public Codex provider docs cover the initial `--codex-login` flow and the local `1455` callback but do not document token-refresh behavior, expiry handling, or a status command. Treat re-auth as empirically validated, not doc-guaranteed. This matters for an always-on remote host: a silently expired Codex token turns every proxied request into an auth failure with no native Claude fallback.

- [ ] Locate where the OAuth credentials are stored (`auth-dir`: `~/.cli-proxy-api` natively, or the mounted `cliproxy-auth` volume in Docker). Confirm the credential file is present after login and never committed.
- [ ] Determine empirically whether CLIProxyAPI refreshes the Codex token automatically while running, or whether refresh only happens at startup. Record the observed token lifetime.
- [ ] Write down the exact re-login recovery command for each deployment:
  - Docker: `docker compose run --rm -p 127.0.0.1:1455:1455 cliproxyapi --codex-login --no-browser`, then `docker compose up -d`.
  - Native: `cliproxyapi --codex-login`, then restart the service.
- [ ] Add a lightweight health check that distinguishes an expired Codex token from a proxy-down state, so a re-login is triggered rather than a blind restart. A failing authenticated request through `http://127.0.0.1:8317` with a valid local API key indicates the upstream Codex credential, not the proxy, is the problem.
- [ ] Decide how re-auth is surfaced remotely: the `1455` browser callback requires host access, so a remote-only session cannot complete a fresh OAuth login. Confirm the token lifetime is long enough for the intended remote-use windows, or plan periodic on-host re-login.

### Why the tweet alias is adjusted

The post's exact alias sets `CLAUDE_CODE_SUBAGENT_MODEL=gpt-5.6-sol`. Current Claude Code model resolution gives that environment variable priority over each subagent file's `model` frontmatter. Keeping it would force every Luna and GPT-5.5 subagent request onto Sol.

For this setup:

- Start the proxied parent with `claude --model fable`; the provider-local mapping resolves that role to GPT-5.6 Sol.
- Omit `CLAUDE_CODE_SUBAGENT_MODEL` so each agent file's Fable/Opus/Sonnet/Haiku role is respected.
- Omit `CLAUDE_CODE_EFFORT_LEVEL` (a single global value that cannot vary per model) and any CLIProxyAPI `payload.override` for `reasoning.effort`; both hard-lock effort. Use per-model `payload.default` rules instead (Phase 2 effort-policy step) so each model gets a baseline while per-subagent and per-turn choices still win.
- Declare effort capabilities per mapped role. Sol and Luna support `low` through `max`; GPT-5.5 and GPT-5.4 mini support `low` through `xhigh`. OpenAI `none` is intentionally not exposed.
- Keep the concurrency and tool-search settings from the post initially; change them only after the baseline works.

**Capability-declaration caveat (verified 2026-07-20).** Claude Code's `model-config` docs state that the `_NAME`, `_DESCRIPTION`, and `_SUPPORTED_CAPABILITIES` companion variables "take effect on third-party providers such as Amazon Bedrock, Google Cloud's Agent Platform, and Microsoft Foundry," and that only `_NAME` and `_DESCRIPTION` "also take effect when `ANTHROPIC_BASE_URL` points to an LLM gateway." A custom base URL like CLIProxyAPI is treated as a gateway, so `_SUPPORTED_CAPABILITIES` is likely ignored on this path. The friendly GPT display names will still appear, but selectable per-role effort may not. Two consequences:

- Behind a gateway, capability detection falls back to model-ID pattern matching (a `gpt-*` ID matches no Claude pattern, so `/effort` may be absent) or to gateway model discovery. Set `CLAUDE_CODE_ENABLE_GATEWAY_MODEL_DISCOVERY=1` and confirm CLIProxyAPI's `/v1/models` reports the effort capability metadata for each model. Treat "is `/effort` selectable through the proxy?" as a mandatory live gate, not an assumption.
- Effort strategy regardless of whether `/effort` works: set per-model **`default`** rules in CLIProxyAPI's `payload` config (see Phase 2's effort-policy step). `default` fills `reasoning.effort` only when the client omits it, so it gives a guaranteed per-model baseline (`high` for sol/luna, `medium` for 5.5/5.4-mini) that reaches the model even if Claude Code never exposes the control, while still yielding to any effort the client does send. Do not use `override` here — `override` force-replaces the client value and would erase per-subagent and per-turn choices.
- If `_SUPPORTED_CAPABILITIES` ever does take effect here, note the doc rule: "listed capabilities are enabled and unlisted capabilities are disabled." The value `effort,xhigh_effort,max_effort` omits `thinking`, `adaptive_thinking`, and `interleaved_thinking`, so those would be turned off. Add them if that reasoning behavior is wanted through the proxy.

## Phase 3: isolated GPT-named Claudex agents

- [x] Store Claudex user agents under `~/.claudex/agents/`. Keep native agents under `~/.claude/agents/`.
- [x] Use this compatibility map:

  | Claudex agent name | Agent frontmatter | Proxy destination | Available GPT effort |
  | --- | --- | --- | --- |
  | parent session | `--model fable` | GPT-5.6 Sol | `low`, `medium`, `high`, `xhigh`, `max` |
  | `gpt-5-6-luna` | `model: opus` | GPT-5.6 Luna | `low`, `medium`, `high`, `xhigh`, `max` |
  | `gpt-5-5` | `model: sonnet` | GPT-5.5 | `low`, `medium`, `high`, `xhigh` |
  | `gpt-5-4-mini` | `model: haiku` | GPT-5.4 mini | `low`, `medium`, `high`, `xhigh` |

- [x] Add `~/.claudex/agents/gpt-5-6-luna.md`:

  ```markdown
  ---
  name: gpt-5-6-luna
  description: GPT-5.6 Luna worker for delegated analysis, implementation, and independent review.
  model: opus
  ---

  Complete the delegated task independently. Report findings, changes, verification, and remaining risks.
  ```

- [x] Add equivalent `gpt-5-5` and `gpt-5-4-mini` agents using `model: sonnet` and `model: haiku`. A fourth agent `gpt-5-6-sol` (`model: fable`) was also added, so Sol is reachable as a subagent and not only as the parent. None of the four set `effort` in frontmatter.
- [ ] Revisit effort layering now that the Phase 2C proxy baseline is known to be inert on `/v1/messages`. With no `effort` in frontmatter and no proxy default, each subagent inherits whatever effort the parent sends. If Luna-as-sub should be cheaper than Luna-as-main, that now requires an explicit `effort` in the agent frontmatter — there is no proxy-side floor to fall back on.
- [ ] Open `/agents` in Claudex and verify all four GPT-named agents are discovered. Explicit invocation can use `@agent-gpt-5-6-luna`, `@agent-gpt-5-5`, or `@agent-gpt-5-4-mini`.
- [ ] Run one bounded delegation through each agent. Check CLIProxyAPI logs to prove the child requests resolved to Luna, GPT-5.5, and GPT-5.4 mini. Do not accept only the subagent's self-reported model name as proof.
- [ ] Test context compaction in a disposable long session before relying on this setup for production work.

Compatibility gate: the agent names describe the real GPT destinations, but `model` must remain the corresponding supported Claude role so the configured proxy mapping performs the translation. Treat the live Agent-tool and effort smoke tests as mandatory.

## Phase 4: native Fable 5, Opus 4.8, Sonnet 5, and Haiku

- [x] Preserve the existing subscription-authenticated Claude Code environment as the native provider. Do not place proxy environment variables in global shell startup files or the shared native `~/.claude/settings.json`. All proxy variables live inside the `claudex` wrapper's `exec env` line only.
- [x] Continue using the existing `~/.local/bin/claude` executable and normal `~/.claude` state. Do not install Claude Code again. The wrapper execs that same binary.
- [ ] In native Claude Code, verify the normal aliases resolve to the expected subscription models without any proxy variables:

  - `fable` -> Fable 5
  - `opus` -> Opus 4.8
  - `sonnet` -> Sonnet 5
  - `haiku` -> the current Haiku model available to the account

- [ ] Keep native agents and native `CLAUDE.md` independent from the GPT-named Claudex agents and instructions.
- [ ] Do not add Claude OAuth to CLIProxyAPI until both independent profiles pass their smoke tests.

### Optional terminal convenience command

A `claudex` shell function or wrapper is useful for terminal sessions, but it is not a second Claude installation. It launches the same `claude` binary with the isolated `~/.claudex` configuration and CLIProxyAPI provider environment. `ANTHROPIC_MODEL=fable` provides the default Sol role, while an explicit `--model` and `--effort` remain selectable:

```zsh
claudex() {
  env -u ANTHROPIC_API_KEY \
  CLAUDE_CONFIG_DIR="$HOME/.claudex" \
  ANTHROPIC_BASE_URL=http://127.0.0.1:8317 \
  ANTHROPIC_AUTH_TOKEN="$CLIPROXY_LOCAL_API_KEY" \
  ANTHROPIC_MODEL=fable \
  ANTHROPIC_DEFAULT_FABLE_MODEL=gpt-5.6-sol \
  ANTHROPIC_DEFAULT_FABLE_MODEL_NAME='GPT-5.6 Sol' \
  ANTHROPIC_DEFAULT_FABLE_MODEL_SUPPORTED_CAPABILITIES=effort,xhigh_effort,max_effort \
  ANTHROPIC_DEFAULT_OPUS_MODEL=gpt-5.6-luna \
  ANTHROPIC_DEFAULT_OPUS_MODEL_NAME='GPT-5.6 Luna' \
  ANTHROPIC_DEFAULT_OPUS_MODEL_SUPPORTED_CAPABILITIES=effort,xhigh_effort,max_effort \
  ANTHROPIC_DEFAULT_SONNET_MODEL=gpt-5.5 \
  ANTHROPIC_DEFAULT_SONNET_MODEL_NAME='GPT-5.5' \
  ANTHROPIC_DEFAULT_SONNET_MODEL_SUPPORTED_CAPABILITIES=effort,xhigh_effort \
  ANTHROPIC_DEFAULT_HAIKU_MODEL=gpt-5.4-mini \
  ANTHROPIC_DEFAULT_HAIKU_MODEL_NAME='GPT-5.4 mini' \
  ANTHROPIC_DEFAULT_HAIKU_MODEL_SUPPORTED_CAPABILITIES=effort,xhigh_effort \
  CLAUDE_CODE_ENABLE_GATEWAY_MODEL_DISCOVERY=1 \
  CLAUDE_CODE_MAX_TOOL_USE_CONCURRENCY=3 \
  ENABLE_TOOL_SEARCH=false \
  command claude "$@"
}
```

Examples:

```bash
claudex                                      # Fable role -> GPT-5.6 Sol
claudex --model opus --effort low            # Opus role -> GPT-5.6 Luna
claudex --model sonnet --effort xhigh        # Sonnet role -> GPT-5.5
claudex --model haiku --effort medium        # Haiku role -> GPT-5.4 mini
```

Use a function instead of a simple alias so arguments such as `claudex --resume` are forwarded reliably. T3 Desktop will not normally load an interactive shell alias/function; configure the same binary, `CLAUDE_CONFIG_DIR`, and provider environment variables in the T3 provider instead.

### Optional hybrid experiment

Use this only if a single parent must reach both model families and accepting native Claude as the parent is acceptable. It is not needed for the requested separate-session setup.

- [ ] Install and log in to the standalone Codex CLI first.
- [ ] In native Claude Code, install OpenAI's official Codex plugin for Claude Code from `openai/codex-plugin-cc`.
- [ ] Run the plugin setup and verify it can invoke explicit `gpt-5.6-sol`, `gpt-5.6-luna`, and `gpt-5.5` tasks.
- [ ] Keep Opus/Sonnet as ordinary native Claude Code subagents.
- [ ] Reject this option if Sol must remain the top-level orchestrator.

CLIProxyAPI also documents Claude OAuth, so a Sol-first mixed-provider experiment may be possible without a custom bridge. Treat that as a separate research ticket: add Claude OAuth to CLIProxyAPI, verify exact model routing, and confirm subagent behavior without disturbing the working native profile. The baseline does not depend on it.

## Phase 5: T3 Code Desktop and HTTP backend

- [x] Install the current T3 Code Desktop release.

  ```bash
  brew install --cask t3-code
  ```

- [ ] Also verify the CLI entrypoint, because it is useful for headless serving, pairing, auth/session revocation, and diagnostics.

  ```bash
  npx t3@latest --help
  npx t3@latest serve --help
  npx t3@latest auth --help
  ```

- [x] Open T3 Desktop and configure two Claude providers.

  As built, the two provider instances in `~/.t3/userdata/settings.json` are `claudeAgent` (native, `binaryPath: claude`) and `claudex` (`binaryPath: /Users/<username>/.local/bin/claudex`). The environment block below is **not** entered into T3's environment fields — the `claudex` wrapper applies all of it, so T3 only needs the binary path. Entering them in T3 is not merely redundant: the wrapper's final `exec env VAR=... "$CLAUDE_BIN"` sets each one as a literal assignment, which overrides whatever T3 exported, so a value typed into T3 has no effect and logs nothing. That keeps one authoritative copy of the mapping and makes the CLI and T3 behave identically. The variable list below is retained as the reference for what the wrapper sets:

  **Claude Native**

  ```text
  Display name: Claude Native
  Binary path: /Users/<mac-user>/.local/bin/claude
  Claude HOME path: empty
  Environment variables: none of the proxy variables
  ```

  **Claude via CLIProxyAPI**

  ```text
  Display name: Claude via CLIProxyAPI
  Binary path: /Users/<mac-user>/.local/bin/claude
  Claude HOME path: empty
  CLAUDE_CONFIG_DIR=/Users/<mac-user>/.claudex
  ANTHROPIC_BASE_URL=http://127.0.0.1:8317
  ANTHROPIC_AUTH_TOKEN=<CLIPROXY_LOCAL_API_KEY>
  (do not add ANTHROPIC_API_KEY at all; a GUI field cannot unset an inherited key, and empty-string behavior is undocumented. Confirm the launched process has no ANTHROPIC_API_KEY in its environment.)
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

  Put these values in the provider's Environment variables section, not in launch arguments. Mark the local API key as sensitive. Do not set `CLAUDE_CODE_SUBAGENT_MODEL` or `CLAUDE_CODE_EFFORT_LEVEL`; those would override per-agent model roles or selectable effort. Two deviations from the block above are intentional in the shipped wrapper: `ANTHROPIC_DEFAULT_*_MODEL` are set to the friendly alias strings (`GPT-5.6 Sol`, `GPT-5.6 Luna`, `GPT 5.5`, `GPT 5.4 mini`) rather than the raw upstream ids; and `ANTHROPIC_MODEL=opus` is set to pin the default main role. Raw ids are unusable — `oauth-model-alias` replaces the upstream id, so `gpt-5.6-luna` stops resolving once aliased. That leaves the friendly names and the `claude-*` slugs, equally valid aliases for the same upstream models. The split between them is by client. The CLI applies reasoning effort itself, so the friendly names keep honest labels there — but only because `ANTHROPIC_DEFAULT_*_SUPPORTED_CAPABILITIES` tells Claude Code these custom names accept effort at all (see `SETUP.md`); without it the flag is ignored. The Claude slugs exist for T3, whose `claudeAgent` driver drops effort for anything that is not a built-in Claude slug. Both profiles can leave Claude HOME path empty: native Claude then uses its default `~/.claude`, while the proxy provider's `CLAUDE_CONFIG_DIR` redirects only Claudex to `~/.claudex`. Select Fable as the default main role through T3 if its provider UI supports a default without locking the thread picker.

- [ ] Start one T3 thread with **Claude Native** and verify Fable, Opus, Sonnet, and Haiku retain their normal native mappings.
- [ ] Start a different T3 thread with **Claude via CLIProxyAPI** and verify it loads `~/.claudex/CLAUDE.md`, discovers the GPT-named agents, and routes Fable, Opus, Sonnet, and Haiku to Sol, Luna, GPT-5.5, and GPT-5.4 mini.
- [ ] Confirm `/status` and CLIProxyAPI logs prove the Claudex thread uses the proxy and isolated configuration.
- [ ] Verify the T3 model picker end to end against a running proxy. The `claude-*` aliases and the `hiddenModels` picker state are written (`cliproxy/config.yaml`, `cliproxy/example.config.yaml`, `.t3/example.client-settings.json`) but **not** tested: restart the proxy (`./cliproxy/stop.sh` then `./cliproxy/start.sh` — `config.yaml` is a read-only bind mount read at startup, and `start.sh` alone will not recreate a running container), then confirm `Claude Fable 5`, `Claude Opus 4.8`, `Claude Sonnet 5` and `Claude Haiku 4.5` all resolve, including the Sonnet 5 1M context toggle (`claude-sonnet-5[1m]`).
- [x] Verify what `max` does on the `claude-sonnet-5` row. Upstream `gpt-5.5` supports `none, low, medium, high, xhigh` and has no `max`. `claude-sonnet-4-6`'s `max` → `high` rewrite was accidentally protective; Sonnet 5 has no such rewrite, so picking "Max" sends a literal `max` to a model that does not advertise it. **Tested: it fails — the request errors rather than falling back to a default.** `payload.default` is no backstop: it only fills an *omitted* effort, and "Max" sends one explicitly. T3 offers no way to remove `max` from the picker (the effort list is baked into the built-in slug's descriptor; `hiddenModels` hides whole rows only), so this stands as a usage constraint: **`xhigh` is the top usable level on the Sonnet 5 row.**
- [ ] Treat native Claude and Claudex as separate session families. Do not assume a thread can switch providers safely when the providers use different configuration directories and credential stores.
- [ ] Optionally configure a third, direct Codex provider only after installing and logging in to the standalone Codex CLI. This is not required for using Codex models through the Claude Code harness.
- [ ] Create a disposable T3 project and run one prompt through each provider.
- [x] Record the actual local T3 backend port. Confirmed `127.0.0.1:3773` (matches the documented default). Verified with `lsof -nP -iTCP -sTCP:LISTEN`; the listener is loopback-only, so Network access is off and no LAN listener exists.

### Choose one T3 server mode

Preferred first attempt:

- [ ] Use the Desktop-managed local backend and proxy its loopback endpoint with `cloudflared`.
- [x] Leave **Network access** off if the backend is already reachable at `127.0.0.1:<T3_PORT>` from the same Mac. Confirmed on the installed release: with Network access off, T3 still binds `127.0.0.1:3773` and no LAN listener appears.
- [ ] If Desktop requires **Network access** to create remote pairing credentials or expose the backend, enable it only after checking the resulting listeners and local firewall exposure.

Headless fallback:

```bash
npx t3@latest serve --host 127.0.0.1
```

- [ ] Run only one T3 backend at a time; avoid a Desktop/headless port or state conflict.
- [ ] Save the one-time owner pairing URL securely. T3 exchanges it for a device session; the URL/token must be treated as a password until used or revoked.
- [ ] Use `t3 auth` to inspect and revoke old pairing credentials and device sessions.
- [ ] Remember the current remote limitation: remote GUIs may not support adding projects. Add required projects from the server machine with `t3 project ...` if needed.

## Phase 6: Cloudflare DNS, Tunnel, and Access

Prerequisites:

- [x] Put the chosen domain/zone on Cloudflare DNS and confirm its nameservers are active. Confirmed active 2026-07-21.
- [x] Choose a single-label hostname such as `code.example.com`. `code.example.com`.
- [x] Decide the exact allowed email address and the Cloudflare account/IdP used to authenticate it. `you@example.com`, authenticated via the built-in **Cloudflare** IdP (login with the Cloudflare account; MFA inherited from account 2FA).
- [x] Use a one-hour Access application/policy session as the initial "short session" value. Adjust only after real use. Both app and policy set to `1h`.

Implementation note: 6A/6B were done via the Cloudflare REST API with a scoped, short-lived token instead of the dashboard + `cloudflared tunnel login`. This avoids writing an account-wide `~/.cloudflared/cert.pem` (10-year, manage-all-tunnels credential). The tunnel was created with `POST /accounts/{id}/cfd_tunnel` (`config_src: local`) and a locally generated `tunnel_secret`; `cloudflared tunnel run` works from `config.yml` + the `<UUID>.json` credentials file with no `cert.pem` present. IDs live only on the host / in Cloudflare, not in git. Delete the setup token when done.

### 6A. Configure Access before starting public ingress

- [x] In Cloudflare Zero Trust, configure an identity provider. Org has exactly one IdP, type `cloudflare` (the built-in Cloudflare identity provider), id `a3c84991-...`. App pins `allowed_idps` to it with `auto_redirect_to_identity: true`.
- [~] Turn on independent MFA at the organization level. Not used: MFA rides the Cloudflare account's own 2FA via the Cloudflare IdP (account 2FA enabled). AMR-based MFA rules only support Okta/Entra/OIDC/SAML, and free-tier availability of Independent MFA is unconfirmed. Revisit if switching IdPs.
- [x] Create a self-hosted Access application for `code.<domain>`. App `T3 Code`, id `aaeeddb3-...`, `aud 77b4e427...`, `session_duration 1h`.
- [x] Create an Allow policy with an exact identity selector: reusable account-level policy `<policy-id>-...`, `decision allow`, `include: [{email: you@example.com}]`, `1h`.

  ```text
  Action: Allow
  Include: Emails
  Value: <your-exact-email>
  Session duration: 1 hour
  Independent MFA: required, 1 hour
  ```

- [x] Do not use `Include Everyone`. Single email include only.
- [x] Do not use `Include Login Methods: One-time PIN` by itself. No OTP IdP configured; only the Cloudflare IdP.
- [ ] Test the policy with the intended email and a different email before starting the tunnel. Pending — needs a browser login (see 6C verification). Edge gate already confirmed: unauthenticated request 302s to the Access login with the correct `aud`.

### 6B. Install and create a locally managed Tunnel

- [x] Install `cloudflared`. Present at `/opt/homebrew/bin/cloudflared`. Not yet configured — `~/.cloudflared` does not exist, so `tunnel login`/`create` are still to run.

  ```bash
  brew install cloudflared
  cloudflared version
  ```

- [x] Authenticate the CLI and create the named tunnel. Done via API instead of `cloudflared tunnel login` — tunnel `t3-code`, UUID `1c426c95-...`, `config_src: local`. No `cert.pem` written.

  ```bash
  # API path used (no cert.pem): generate a 32-byte secret, then
  # POST /accounts/{id}/cfd_tunnel {"name":"t3-code","config_src":"local","tunnel_secret":"<b64>"}
  # write ~/.cloudflared/<UUID>.json = {AccountTag, TunnelSecret, TunnelID}
  ```

- [x] Create `~/.cloudflared/config.yml` locally. Do not commit the credentials JSON or a config containing secrets. Both files written under `~/.cloudflared/` (0600 credentials); nothing committed.

  ```yaml
  tunnel: <TUNNEL_UUID>
  credentials-file: /Users/<mac-user>/.cloudflared/<TUNNEL_UUID>.json

  ingress:
    - hostname: code.<domain>
      service: http://127.0.0.1:<T3_PORT>
    - service: http_status:404
  ```

- [x] Validate the ingress configuration and hostname match. `ingress validate` → OK; `ingress rule` matches rule #0 → `http://127.0.0.1:3773`.

  ```bash
  cloudflared tunnel ingress validate
  cloudflared tunnel ingress rule https://code.<domain>
  ```

- [x] Create the DNS CNAME route. Done via DNS API instead of `route dns` (which needs `cert.pem`): `POST /zones/{id}/dns_records` CNAME `code` → `<UUID>.cfargotunnel.com`, proxied.

- [x] Confirm the generated proxied CNAME points at `<TUNNEL_UUID>.cfargotunnel.com`. Confirmed proxied; `code.example.com` resolves to Cloudflare edge IPs.

### 6C. Start and persist the Tunnel

- [x] Start T3 first, then run the Tunnel interactively. T3 (`:3773`) and proxy (`:8317`) up; `cloudflared tunnel run t3-code` running, 4 QUIC connections registered (ord).

  ```bash
  cloudflared tunnel run t3-code
  ```

- [x] Confirm the tunnel is Healthy and the local origin does not return a 502. Healthy; edge returns Access 302 (not 1033/502).
- [ ] From a private/incognito browser, visit `https://code.<domain>`. Confirm Cloudflare Access blocks the T3 response until the exact email and MFA succeed. Edge gate confirmed via curl (302 → Access login, correct `aud`); the actual login + wrong-email rejection still need a browser test by the user.
- [ ] Complete T3's separate one-time pairing flow. Confirm a second browser/device without a T3 session cannot use the backend even after Cloudflare login.
- [ ] Verify a live agent response streams through the browser. T3 uses WebSockets, and Cloudflare Tunnel supports WebSockets, but the end-to-end flow still needs a real streaming test.
- [ ] After validation, do not install a login/boot launch agent. Instead start the stack on demand with a single orchestration script (see Phase 6D). This keeps startup explicit and ordered rather than tied to login.

### 6D. Startup orchestration script

Start the whole stack from one script rather than login launch agents. The Mac is kept awake separately with `caffeinate` on constant power, so the script only needs to bring services up in dependency order and fail loudly if any step is not healthy.

- [ ] Write a `start.sh` that runs, in order and with health gates:

  1. `docker compose up -d` for CLIProxyAPI, then poll `http://127.0.0.1:8317` with the local API key until it answers. Fail fast if the Codex token is expired (see Phase 2D) so re-login happens before dependents start.
  2. Start the single T3 backend (Desktop-managed, or `npx t3@latest serve --host 127.0.0.1` for the headless path). Confirm exactly one backend is listening on `127.0.0.1:<T3_PORT>`.
  3. `cloudflared tunnel run t3-code`, then confirm the tunnel reports Healthy and the origin does not 502.

  ```bash
  # start.sh (sketch; fill in health checks and the real T3_PORT)
  set -euo pipefail

  docker compose -f "$HOME/cliproxy/docker-compose.yml" up -d
  until curl -fsS -H "Authorization: Bearer $CLIPROXY_LOCAL_API_KEY" http://127.0.0.1:8317/v1/models >/dev/null; do
    sleep 1
  done

  # start T3 backend here (Desktop app already running, or the headless serve command)

  cloudflared tunnel run t3-code
  ```

  Partially done: `cliproxy/start.sh` covers step 1 only (`docker compose up -d` plus a 30-second poll of `/v1/models`, treating any non-`000` response as up, since an unauthenticated 401 proves the listener is live). Steps 2 and 3 — the T3 backend and the tunnel — are not yet scripted, and neither is the expired-Codex-token check.

- [ ] Write a matching `stop.sh` that stops the tunnel, stops the T3 backend, and runs `docker compose down` in reverse order. `cliproxy/stop.sh` currently only runs `docker compose down`.
- [x] Keep `start.sh`/`stop.sh` and `docker-compose.yml` outside this repository, or ensure no secrets (`CLIPROXY_LOCAL_API_KEY`, tunnel credentials) are committed. Read secrets from the environment or a secret store, not literals. Satisfied by the second option: the scripts and compose file are tracked but hold no secrets, and `.gitignore` covers `**/config.yaml`, `**/auth/`, `**/*.log`, and `**/.env*`. Re-verify with `git ls-files cliproxy` after adding tunnel credentials.
- [ ] The Codex OAuth `1455` callback needs on-host browser access, so re-login is an on-host action; `start.sh` should detect the expired-token case and stop with a clear "run --codex-login" message rather than starting a broken tunnel.

## Phase 7: remote browser validation

- [ ] Prefer the T3 web UI served through `https://code.<domain>` so the UI, Access cookie, API, and WebSocket remain on one origin.
- [ ] If using T3's hosted UI at `https://app.t3.codes`, use its HTTPS pairing form only after authenticating directly to the backend hostname. The hosted UI connects directly to the backend; it is not a relay.
- [ ] Treat hosted-UI plus Cloudflare Access as a compatibility gate. Cross-site Access cookies, CORS, or WebSocket authentication may fail under browser privacy settings. Do not weaken Access to fix this; use the same-origin T3 UI or a trusted private-network option instead.
- [ ] Test from cellular or a network outside the home LAN.
- [ ] Verify the Mac remains awake, T3 remains running, CLIProxyAPI remains running, and the tunnel reconnects after logout/login or reboot as intended.
- [ ] Test Access expiry after one hour and confirm reauthentication plus MFA are required as configured.
- [ ] Revoke the test T3 session with `t3 auth` and verify the browser loses agent access.

## Security acceptance checklist

- [ ] Only `code.<domain>` routes through the tunnel; unmatched ingress returns 404.
- [x] CLIProxyAPI is reachable only on `127.0.0.1:8317` and requires the configured local API key. Verified 2026-07-21: the compose mapping is `127.0.0.1:8317:8317` and `lsof` shows only the loopback listener. `remote-management.allow-remote` is `false` with an empty secret, so the management API is off.
- [x] T3 listens only on loopback unless LAN access is explicitly required. Verified: `127.0.0.1:3773` only.
- [ ] Cloudflare Access policy allows one exact email/account and denies everyone else by default.
- [ ] Independent MFA is required.
- [ ] Access and MFA session durations are short and tested.
- [ ] T3 pairing URLs are never committed, logged in tickets, or shared in screenshots.
- [ ] Old T3 device sessions are revocable and audited periodically.
- [x] `~/.codex/auth.json`, the proxy auth directory, the CLIProxyAPI local API key, Cloudflare tunnel credentials, T3 secrets, and any `config.yaml`/`docker-compose.yml`/`start.sh` holding secrets are never added to this repository. Verified 2026-07-21 — `cliproxy/config.yaml` (holds the API key) and `cliproxy/auth/` (holds the Codex OAuth JSON) are both gitignored and untracked. Recheck once tunnel credentials exist; `~/.cloudflared/*.json` lives outside the repo, which is the safer default.
- [ ] The public browser provider is run with the least practical agent filesystem/shell permissions. Compromise of this UI is equivalent to remote control of local coding agents.
- [ ] Cloudflare, T3, proxy (including the pinned CLIProxyAPI Docker image tag), Docker Desktop, Codex CLI, Claude Code, and Node versions are recorded after installation for reproducibility.

## Open questions / live-test gates

- [x] Does the ChatGPT subscription expose all four mapped GPT IDs through CLIProxyAPI today? Confirmed 2026-07-21 on a ChatGPT Plus account: `/v1/models` returns `gpt-5.6-sol`, `gpt-5.6-luna`, `gpt-5.5`, and `gpt-5.4-mini` (plus `gpt-5.6-terra`, `gpt-5.4`, `gpt-5.3-codex-spark`). CLIProxyAPI `v7.2.92`.
- [ ] Does Claude Code `2.1.215` display all four friendly mapped model names behind the custom base URL? (Names use `_NAME`, which the docs confirm works behind a gateway.)
- [x] Is `/effort` actually selectable through the proxy? Answered, and the answer differs per client. **CLI:** yes — `ANTHROPIC_DEFAULT_*_SUPPORTED_CAPABILITIES` in the `claudex` wrapper is enough to make Claude Code offer `/effort` on the friendly names. **T3:** not via any proxy or env setting. T3's `claudeAgent` driver only passes `effort` to the Agent SDK for built-in Claude model slugs; a custom model resolves to an empty capability descriptor list, `resolveClaudeEffort` returns `undefined`, and the selection is dropped before the SDK call — the value never leaves T3, so no proxy config can recover it. Worked around by adding a second alias set in `oauth-model-alias` mapping built-in slugs (`claude-fable-5`, `claude-opus-4-8`, `claude-sonnet-5`, `claude-haiku-4-5`, plus `[1m]` variants) onto the same upstream models, which makes T3 attach effort (`low`/`medium`/`high`/`max` → `low`/`medium`/`high`/`xhigh`). The Sonnet route is `claude-sonnet-5`, not `claude-sonnet-4-6`: `normalizeClaudeCliEffort` rewrites `xhigh` → `max` for every slug except `claude-fable-5`, `claude-opus-4-8` and `claude-sonnet-5`, and rewrites `max` → `high` for `claude-sonnet-4-6` alone — so 4.6 silently loses its top effort level while Sonnet 5 passes both `xhigh` and `max` through unchanged. `claude-sonnet-4-6` and `claude-sonnet-4-6[1m]` remain aliased (many aliases can share one upstream id) but are hidden in `.t3/example.client-settings.json`. Sonnet 5 exposes a 200k/1m context selector, so `claude-sonnet-5[1m]` is aliased too; without it the 1M pick returns `502 unknown provider`. Known tradeoff: under those slugs the model believes it is Claude, so self-identification and model-conditional logic are wrong; proxy logs are the only ground truth. Haiku 4.5 has no effort selector in T3, so GPT-5.4 mini gets no effort control there. The Phase 2C `payload.default` baseline does **not** apply as originally assumed — see the correction in 2C.
- [ ] Does CLIProxyAPI refresh the Codex OAuth token automatically, and what is the observed token lifetime before an on-host `--codex-login` is required?
- [ ] Does T3 pass `CLAUDE_CONFIG_DIR=/Users/<mac-user>/.claudex` unchanged to the CLIProxyAPI-backed Claude process and keep its sessions separate from native `~/.claude` sessions?
- [ ] Does the T3 Desktop-managed backend remain reachable from same-host `cloudflared` while Network access is off? Half-answered: with Network access off the backend still binds `127.0.0.1:3773`, which is what a same-host `cloudflared` origin needs. The end-to-end check waits on the tunnel.
- [ ] Does the installed T3 release serve its web UI directly at the tunnel hostname, or is hosted `app.t3.codes` pairing required for this mode?
- [ ] Does hosted `app.t3.codes` work with the Access-protected cross-origin WebSocket in the target browsers?
- [ ] Does T3 discover the standalone Codex CLI from the GUI environment, or must its absolute path be configured?

## Sources

- [Claude `claudex` setup artifact supplied with the request](https://claude.ai/code/artifact/<TUNNEL_UUID>#no_universal_links) — reviewed from the user-supplied Markdown export; confirms the invocation-scoped proxy pattern
- [Tibo's CLIProxyAPI/`claudex` post](https://x.com/thsottiaux/status/2076119366647894371) — supplied recipe and environment variables; the user also supplied the full post text because X retrieval was unreliable
- [CLIProxyAPI repository](https://github.com/router-for-me/CLIProxyAPI) — supported OAuth providers and Anthropic-compatible endpoint
- [CLIProxyAPI quick start](https://help.router-for.me/introduction/quick-start) — Homebrew installation, executable, service, and default config path
- [CLIProxyAPI basic configuration](https://help.router-for.me/configuration/basic) — loopback binding, port, management settings, auth directory, and local API keys
- [CLIProxyAPI Codex OAuth](https://help.router-for.me/configuration/provider/codex) — Codex login and browser callback flow
- [CLIProxyAPI Claude Code client](https://help.router-for.me/agent-client/claude-code) — `ANTHROPIC_BASE_URL`, client token, Claude Code v2 model variables, and model selection
- [OpenAI GPT-5.6 model guidance](https://developers.openai.com/api/docs/guides/latest-model) — Sol/Terra/Luna roles, model IDs, and effort levels
- [OpenAI GPT-5.5 model](https://developers.openai.com/api/docs/models/gpt-5.5) — exact model ID, snapshot `gpt-5.5-2026-04-23`, and supported effort levels (no `max`)
- [OpenAI GPT-5.4 mini model](https://developers.openai.com/api/docs/models/gpt-5.4-mini) — exact model ID, subagent/high-volume role, and supported effort levels
- [OpenAI Codex authentication](https://learn.chatgpt.com/docs/auth) — ChatGPT subscription login, API-key login, caching, and credential storage
- [OpenAI Codex CLI](https://learn.chatgpt.com/docs/codex/cli) — current standalone installation flow
- [OpenAI Codex plugin for Claude Code](https://github.com/openai/codex-plugin-cc) — native-Claude-orchestrator hybrid option
- [Claude Code custom subagents](https://code.claude.com/docs/en/sub-agents) — agent files, full model IDs, and `CLAUDE_CODE_SUBAGENT_MODEL` precedence
- [Claude Code `.claude` directory](https://code.claude.com/docs/en/claude-directory) — `CLAUDE_CONFIG_DIR` as the supported override for the default `~/.claude` configuration directory
- [Claude Code model configuration](https://code.claude.com/docs/en/model-config) — Fable/Opus/Sonnet/Haiku aliases, custom display names, gateway model IDs, and per-model effort capabilities
- [Claude Code memory](https://code.claude.com/docs/en/memory) — `CLAUDE.md` behavior and importing `AGENTS.md`
- [Claude model IDs](https://platform.claude.com/docs/en/about-claude/models/model-ids-and-versions) — `claude-opus-4-8` and `claude-sonnet-5`
- [T3 Code README](https://github.com/pingdotgg/t3code) — supported providers, Desktop installation, and CLI entrypoint
- [T3 Code Claude provider guide](https://github.com/pingdotgg/t3code/blob/main/docs/providers/claude.md) — multiple Claude homes and provider environment variables
- [T3 Code Codex provider guide](https://github.com/pingdotgg/t3code/blob/main/docs/providers/codex.md) — Codex home, login, and provider behavior
- [T3 Code remote access guide](https://github.com/pingdotgg/t3code/blob/main/REMOTE.md) — port examples, serving, pairing, hosted UI, WebSockets, and session revocation
- [Cloudflare Tunnel downloads](https://developers.cloudflare.com/cloudflare-one/networks/connectors/cloudflare-tunnel/downloads/) — macOS installation
- [Cloudflare locally managed Tunnel](https://developers.cloudflare.com/tunnel/advanced/local-management/create-local-tunnel/) — login, create, config, DNS route, and run
- [Cloudflare Tunnel DNS records](https://developers.cloudflare.com/cloudflare-one/networks/connectors/cloudflare-tunnel/routing-to-tunnel/dns/) — CNAME behavior
- [Cloudflare Tunnel configuration](https://developers.cloudflare.com/cloudflare-one/networks/connectors/cloudflare-tunnel/do-more-with-tunnels/local-management/configuration-file/) — ingress rules and validation
- [Cloudflare Access policies](https://developers.cloudflare.com/cloudflare-one/access-controls/policies/) — exact email selectors and dangerous broad-policy examples
- [Cloudflare MFA enforcement](https://developers.cloudflare.com/cloudflare-one/access-controls/policies/mfa-requirements/) — independent MFA and session duration
- [Cloudflare Access session management](https://developers.cloudflare.com/cloudflare-one/access-controls/access-settings/session-management/) — application, policy, and MFA sessions
- [Cloudflare Tunnel WebSocket support](https://developers.cloudflare.com/cloudflare-one/faq/cloudflare-tunnels-faq/) — WebSocket compatibility
- [Cloudflare Tunnel macOS service](https://developers.cloudflare.com/tunnel/advanced/local-management/as-a-service/macos/) — login launch agent versus boot daemon
