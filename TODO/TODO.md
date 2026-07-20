# Agent setup TODO

Research date: 2026-07-20
Target host: ARM macOS 26
Target public hostname: `code.<your-domain>`

## Outcome

Build a local agent host with:

- Claude Code running GPT-5.6 Sol through CLIProxyAPI.
- The same Claude Code model-role and subagent definitions resolving to native Claude models or Codex models according to the active provider.
- A native Claude Code provider for Claude Fable 5, Opus 4.8, Sonnet 5, and Haiku.
- T3 Code Desktop for local use and a T3 HTTP/WebSocket backend for remote use.
- Cloudflare Access, Tunnel, and DNS in front of the T3 backend.

## Architecture decision

Use two Claude Code provider profiles in T3 Code:

1. **Claude via CLIProxyAPI**: Codex subscription authenticated through CLIProxyAPI, with Claude Code roles remapped as Fable -> GPT-5.6 Sol, Opus -> GPT-5.6 Luna, Sonnet -> GPT-5.5, and Haiku -> GPT-5.4 mini.
2. **Claude Native**: existing Claude subscription login with the normal Fable, Opus, Sonnet, and Haiku mappings.

Both profiles use the same installed `claude` executable and the same normal Claude home. In T3, leave **Claude HOME path** empty for both profiles so both read `~/.claude/settings.json`, `~/.claude/CLAUDE.md`, agents, skills, MCP configuration, and session state. A second Claude Code installation or second Claude home is not needed. The provider-specific environment variables create the routing separation.

CLIProxyAPI supports both Codex and Claude OAuth providers. This plan only requires Codex OAuth in CLIProxyAPI because the normal Claude Code profile is already authenticated directly to the Claude subscription. Keeping the subscriptions in separate profiles makes routing and credential ownership obvious:

- **Implement first:** one shared Claude Code configuration with provider-specific alias resolution.
- **Native profile:** `fable`, `opus`, `sonnet`, and `haiku` retain their normal Claude meanings.
- **CLIProxyAPI profile:** the same aliases resolve to Sol, Luna, GPT-5.5, and GPT-5.4 mini respectively.
- **Not required for this plan:** Claude OAuth inside CLIProxyAPI or a mixed GPT/Claude subagent tree. CLIProxyAPI may make that experiment possible, but it needs a separate live compatibility test and is outside the requested two-session design.

The shared home means a single alias-based agent definition works in both profiles. Use `model: fable`, `model: opus`, `model: sonnet`, or `model: haiku` in agent frontmatter instead of hard-coding provider-specific model IDs. Keep all CLIProxyAPI variables scoped to the CLIProxyAPI T3 provider or the `claudex` invocation; never put them in shared `~/.claude/settings.json`.

Do not expose CLIProxyAPI through Cloudflare. Explicitly bind it to `127.0.0.1`; its documented default host setting otherwise listens on all interfaces. Configure a strong local API key even though only T3 is exposed publicly. Expose only T3 Code through the tunnel.

The Codex CLI is not required for the proxy-backed Claude Code profile. `cliproxyapi --codex-login` performs and stores its own ChatGPT/Codex OAuth login. Install the standalone Codex CLI only if T3 should also offer its native Codex provider, or if the optional official Codex plugin for native Claude Code will be used.

### Session layout

```text
Native Claude session
  same claude binary
  shared ~/.claude configuration and existing Claude subscription login
  no ANTHROPIC_BASE_URL override
  Fable 5 / Opus 4.8 / Sonnet 5 / Haiku

Codex-model session in Claude Code harness
  same claude binary
  same shared ~/.claude configuration
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
- [ ] Install T3 Code. `t3` is not currently on `PATH`.
- [ ] Install `cloudflared`. It is not currently on `PATH`.

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

- [ ] Install the current Homebrew formula.

  ```bash
  brew install cliproxyapi
  cliproxyapi --help
  ```

- [ ] Before starting the service, edit the Homebrew configuration file. On an Apple Silicon Homebrew installation the default path is normally `/opt/homebrew/etc/cliproxyapi.conf`; confirm it with `brew --prefix` if needed. Use a newly generated high-entropy value for `<CLIPROXY_LOCAL_API_KEY>` and never commit it.

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

  The explicit host is mandatory. CLIProxyAPI documents an empty host as listening on every interface. An empty management secret disables the management API; leave remote management off.

- [ ] Authenticate CLIProxyAPI directly with the Codex subscription.

  ```bash
  cliproxyapi --codex-login
  ```

  This launches CLIProxyAPI's own ChatGPT/Codex OAuth flow. It does not require the Codex CLI and does not reuse the native Claude Code login. Use `--no-browser` only if the normal browser callback flow cannot be used.

- [ ] Start the service and confirm the exact loopback listener.

  ```bash
  brew services start cliproxyapi
  ```

  Expected origin: `http://127.0.0.1:8317`. Stop and fix the configuration if it listens on a LAN address or `0.0.0.0`.

- [ ] Put the same local API key in a private shell environment or secret store as `CLIPROXY_LOCAL_API_KEY`. Do not put it in this repository.
- [ ] Launch a one-off Sol session from the existing shared Claude home using the adjusted Tibo/Theo recipe and the four role mappings.

  ```bash
  ANTHROPIC_BASE_URL=http://127.0.0.1:8317 \
  ANTHROPIC_AUTH_TOKEN="$CLIPROXY_LOCAL_API_KEY" \
  ANTHROPIC_API_KEY= \
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
  CLAUDE_CODE_MAX_TOOL_USE_CONCURRENCY=3 \
  ENABLE_TOOL_SEARCH=false \
  claude --model fable
  ```

- [ ] In the proxied session, run `/status`, verify the base URL and that `fable` resolves to Sol, then perform a harmless tool-call smoke test. Confirm the request appears in CLIProxyAPI logs; this is the gate proving the shared cached Claude login did not bypass the provider environment.
- [ ] Open `/model` and confirm the friendly GPT names appear for all four remapped roles.
- [ ] Use `/effort low`, `/effort medium`, `/effort high`, and `/effort xhigh` in small prompts. Also test `/effort max` on Sol and Luna only. Confirm CLIProxyAPI logs report the requested model and effort.
- [ ] Record `cliproxyapi`'s installed version and the exact GPT model IDs returned by a live request.

### Why the tweet alias is adjusted

The post's exact alias sets `CLAUDE_CODE_SUBAGENT_MODEL=gpt-5.6-sol`. Current Claude Code model resolution gives that environment variable priority over each subagent file's `model` frontmatter. Keeping it would force every Luna and GPT-5.5 subagent request onto Sol.

For this setup:

- Start the proxied parent with `claude --model fable`; the provider-local mapping resolves that role to GPT-5.6 Sol.
- Omit `CLAUDE_CODE_SUBAGENT_MODEL` so each agent file's Fable/Opus/Sonnet/Haiku role is respected.
- Omit `CLAUDE_CODE_EFFORT_LEVEL` and any CLIProxyAPI `payload.override` for `reasoning.effort`; either would lock effort instead of leaving it selectable.
- Declare effort capabilities per mapped role. Sol and Luna support `low` through `max`; GPT-5.5 and GPT-5.4 mini support `low` through `xhigh`. OpenAI `none` is intentionally not exposed.
- Keep the concurrency and tool-search settings from the post initially; change them only after the baseline works.

## Phase 3: shared alias-based Claude Code agents

- [ ] Keep the existing `~/.claude/settings.json`, `~/.claude/CLAUDE.md`, user skills, MCP configuration, and agents as the single shared Claude Code configuration.
- [ ] Define reusable agents with Claude role aliases rather than provider-specific model IDs. The same file then selects a native Claude model under **Claude Native** and the paired GPT model under **Claude via CLIProxyAPI**.
- [ ] Use this compatibility map:

  | Agent frontmatter | Claude Native | Claude via CLIProxyAPI | Available GPT effort |
  | --- | --- | --- | --- |
  | `model: fable` | Fable 5 | GPT-5.6 Sol | `low`, `medium`, `high`, `xhigh`, `max` |
  | `model: opus` | Opus 4.8 | GPT-5.6 Luna | `low`, `medium`, `high`, `xhigh`, `max` |
  | `model: sonnet` | Sonnet 5 | GPT-5.5 | `low`, `medium`, `high`, `xhigh` |
  | `model: haiku` | current Haiku | GPT-5.4 mini | `low`, `medium`, `high`, `xhigh` |

- [ ] For a flexible agent, omit `effort` frontmatter so the session or per-invocation selection controls it. For a stable preset such as a fast worker, add a supported value explicitly:

  ```markdown
  ---
  name: fast-worker
  description: Fast delegated implementation, lookup, and mechanical work. Use when speed matters.
  model: haiku
  effort: low
  ---

  Complete the delegated task. Keep changes scoped, report verification, and return blockers precisely.
  ```

- [ ] Do not put full GPT IDs into shared agent frontmatter unless that agent is intentionally unusable in the native Claude profile.
- [ ] In each provider, open `/agents` and verify the same shared agents are discovered.
- [ ] Run one bounded delegation through each role in each provider. Check CLIProxyAPI logs to prove the proxied child requests resolved to Sol, Luna, GPT-5.5, and GPT-5.4 mini. Do not accept only the subagent's self-reported model name as proof.
- [ ] Test context compaction in a disposable long session before relying on this setup for production work.

Compatibility gate: the role aliases and their effort-capability metadata are native Claude Code configuration surfaces, while the GPT destinations depend on CLIProxyAPI accepting and translating the mapped full model IDs. Treat the live Agent-tool and effort smoke tests as mandatory.

## Phase 4: native Fable 5, Opus 4.8, Sonnet 5, and Haiku

- [ ] Preserve the existing subscription-authenticated Claude Code environment as the native provider. Do not place proxy environment variables in global shell startup files or the shared native `~/.claude/settings.json`.
- [ ] Continue using the existing `~/.local/bin/claude` executable and normal `~/.claude` state. Do not install Claude Code again.
- [ ] In native Claude Code, verify the normal aliases resolve to the expected subscription models without any proxy variables:

  - `fable` -> Fable 5
  - `opus` -> Opus 4.8
  - `sonnet` -> Sonnet 5
  - `haiku` -> the current Haiku model available to the account

- [ ] Use alias-based shared agents so the same definitions work in the CLIProxyAPI profile.
- [ ] Do not add Claude OAuth to CLIProxyAPI until both independent profiles pass their smoke tests.

### Optional terminal convenience command

A `claudex` shell function or wrapper is useful for terminal sessions, but it is not a second Claude installation. It launches the same `claude` binary and shared Claude home with the CLIProxyAPI provider environment. `ANTHROPIC_MODEL=fable` provides the default Sol role, while an explicit `--model` and `--effort` remain selectable:

```zsh
claudex() {
  ANTHROPIC_BASE_URL=http://127.0.0.1:8317 \
  ANTHROPIC_AUTH_TOKEN="$CLIPROXY_LOCAL_API_KEY" \
  ANTHROPIC_API_KEY= \
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

Use a function instead of a simple alias so arguments such as `claudex --resume` are forwarded reliably. T3 Desktop will not normally load an interactive shell alias/function; configure the same binary, shared Claude home, and environment variables in the T3 provider instead.

### Optional hybrid experiment

Use this only if a single parent must reach both model families and accepting native Claude as the parent is acceptable. It is not needed for the requested separate-session setup.

- [ ] Install and log in to the standalone Codex CLI first.
- [ ] In native Claude Code, install OpenAI's official Codex plugin for Claude Code from `openai/codex-plugin-cc`.
- [ ] Run the plugin setup and verify it can invoke explicit `gpt-5.6-sol`, `gpt-5.6-luna`, and `gpt-5.5` tasks.
- [ ] Keep Opus/Sonnet as ordinary native Claude Code subagents.
- [ ] Reject this option if Sol must remain the top-level orchestrator.

CLIProxyAPI also documents Claude OAuth, so a Sol-first mixed-provider experiment may be possible without a custom bridge. Treat that as a separate research ticket: add Claude OAuth to CLIProxyAPI, verify exact model routing, and confirm subagent behavior without disturbing the working native profile. The baseline does not depend on it.

## Phase 5: T3 Code Desktop and HTTP backend

- [ ] Install the current T3 Code Desktop release.

  ```bash
  brew install --cask t3-code
  ```

- [ ] Also verify the CLI entrypoint, because it is useful for headless serving, pairing, auth/session revocation, and diagnostics.

  ```bash
  npx t3@latest --help
  npx t3@latest serve --help
  npx t3@latest auth --help
  ```

- [ ] Open T3 Desktop and configure two Claude providers:

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
  ANTHROPIC_BASE_URL=http://127.0.0.1:8317
  ANTHROPIC_AUTH_TOKEN=<CLIPROXY_LOCAL_API_KEY>
  ANTHROPIC_API_KEY=<empty value>
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
  CLAUDE_CODE_MAX_TOOL_USE_CONCURRENCY=3
  ENABLE_TOOL_SEARCH=false
  ```

  Put these values in the provider's Environment variables section, not in launch arguments. Mark the local API key as sensitive. Do not set `ANTHROPIC_MODEL`, `CLAUDE_CODE_SUBAGENT_MODEL`, or `CLAUDE_CODE_EFFORT_LEVEL` in T3; those could override the interactive main-model choice, per-agent model roles, or selectable effort. Both profiles intentionally have an empty Claude HOME path and therefore share `~/.claude`. Select Fable as the default main role through T3 if its provider UI supports a default without locking the thread picker.

- [ ] Start one T3 thread with **Claude Native** and verify Fable, Opus, Sonnet, and Haiku retain their normal native mappings.
- [ ] Start a different T3 thread with **Claude via CLIProxyAPI** and verify Fable, Opus, Sonnet, and Haiku display the friendly GPT names and route to Sol, Luna, GPT-5.5, and GPT-5.4 mini.
- [ ] Confirm `/status` and CLIProxyAPI logs prove the shared cached Claude subscription did not bypass the proxy environment. If this fails in the installed Claude Code/T3 versions, fall back to a separate Claude home; do not log out the shared native subscription as a workaround.
- [ ] Confirm T3 treats both providers as continuation-compatible because their Claude HOME paths match. Verify switching provider/model on an existing disposable thread before relying on it for real work.
- [ ] Optionally configure a third, direct Codex provider only after installing and logging in to the standalone Codex CLI. This is not required for using Codex models through the Claude Code harness.
- [ ] Create a disposable T3 project and run one prompt through each provider.
- [ ] Record the actual local T3 backend port. Documentation examples use `3773`, but the tunnel configuration must use the port shown by the installed version.

### Choose one T3 server mode

Preferred first attempt:

- [ ] Use the Desktop-managed local backend and proxy its loopback endpoint with `cloudflared`.
- [ ] Leave **Network access** off if the backend is already reachable at `127.0.0.1:<T3_PORT>` from the same Mac. This avoids an unnecessary LAN listener. This is a security-motivated inference; verify it with the installed release.
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

- [ ] Put the chosen domain/zone on Cloudflare DNS and confirm its nameservers are active.
- [ ] Choose a single-label hostname such as `code.example.com`.
- [ ] Decide the exact allowed email address and the Cloudflare account/IdP used to authenticate it.
- [ ] Use a one-hour Access application/policy session as the initial "short session" value. Adjust only after real use.

### 6A. Configure Access before starting public ingress

- [ ] In Cloudflare Zero Trust, configure an identity provider. For a personal deployment, the Cloudflare identity provider with **Restrict to account members** is a simple fit. An existing Google, GitHub, Entra ID, Okta, OIDC, or SAML provider is also valid.
- [ ] Turn on independent MFA at the organization level.
- [ ] Create a self-hosted Access application for `code.<your-domain>`.
- [ ] Create an Allow policy with an exact identity selector:

  ```text
  Action: Allow
  Include: Emails
  Value: <your-exact-email>
  Session duration: 1 hour
  Independent MFA: required, 1 hour
  ```

- [ ] Do not use `Include Everyone`.
- [ ] Do not use `Include Login Methods: One-time PIN` by itself. That would allow any valid email address. If email OTP is used, still restrict the policy to the exact email.
- [ ] Test the policy with the intended email and a different email before starting the tunnel.

### 6B. Install and create a locally managed Tunnel

- [ ] Install `cloudflared`.

  ```bash
  brew install cloudflared
  cloudflared version
  ```

- [ ] Authenticate the CLI and create the named tunnel.

  ```bash
  cloudflared tunnel login
  cloudflared tunnel create t3-code
  cloudflared tunnel list
  ```

- [ ] Create `~/.cloudflared/config.yml` locally. Do not commit the credentials JSON or a config containing secrets.

  ```yaml
  tunnel: <TUNNEL_UUID>
  credentials-file: /Users/<mac-user>/.cloudflared/<TUNNEL_UUID>.json

  ingress:
    - hostname: code.<your-domain>
      service: http://127.0.0.1:<T3_PORT>
    - service: http_status:404
  ```

- [ ] Validate the ingress configuration and hostname match.

  ```bash
  cloudflared tunnel ingress validate
  cloudflared tunnel ingress rule https://code.<your-domain>
  ```

- [ ] Create the DNS CNAME route with the requested CLI flow.

  ```bash
  cloudflared tunnel route dns t3-code code.<your-domain>
  ```

- [ ] Confirm the generated proxied CNAME points at `<TUNNEL_UUID>.cfargotunnel.com`.

### 6C. Start and persist the Tunnel

- [ ] Start T3 first, then run the Tunnel interactively.

  ```bash
  cloudflared tunnel run t3-code
  ```

- [ ] Confirm the tunnel is Healthy and the local origin does not return a 502.
- [ ] From a private/incognito browser, visit `https://code.<your-domain>`. Confirm Cloudflare Access blocks the T3 response until the exact email and MFA succeed.
- [ ] Complete T3's separate one-time pairing flow. Confirm a second browser/device without a T3 session cannot use the backend even after Cloudflare login.
- [ ] Verify a live agent response streams through the browser. T3 uses WebSockets, and Cloudflare Tunnel supports WebSockets, but the end-to-end flow still needs a real streaming test.
- [ ] After validation, install `cloudflared` as a per-user macOS launch agent so it reads `~/.cloudflared/config.yml` and starts at login.

  ```bash
  cloudflared service install
  ```

  Use the non-`sudo` form for a login launch agent. The `sudo` form is a boot launch daemon and expects configuration under `/etc/cloudflared`.

## Phase 7: remote browser validation

- [ ] Prefer the T3 web UI served through `https://code.<your-domain>` so the UI, Access cookie, API, and WebSocket remain on one origin.
- [ ] If using T3's hosted UI at `https://app.t3.codes`, use its HTTPS pairing form only after authenticating directly to the backend hostname. The hosted UI connects directly to the backend; it is not a relay.
- [ ] Treat hosted-UI plus Cloudflare Access as a compatibility gate. Cross-site Access cookies, CORS, or WebSocket authentication may fail under browser privacy settings. Do not weaken Access to fix this; use the same-origin T3 UI or a trusted private-network option instead.
- [ ] Test from cellular or a network outside the home LAN.
- [ ] Verify the Mac remains awake, T3 remains running, CLIProxyAPI remains running, and the tunnel reconnects after logout/login or reboot as intended.
- [ ] Test Access expiry after one hour and confirm reauthentication plus MFA are required as configured.
- [ ] Revoke the test T3 session with `t3 auth` and verify the browser loses agent access.

## Security acceptance checklist

- [ ] Only `code.<your-domain>` routes through the tunnel; unmatched ingress returns 404.
- [ ] CLIProxyAPI listens only on `127.0.0.1:8317` and requires the configured local API key.
- [ ] T3 listens only on loopback unless LAN access is explicitly required.
- [ ] Cloudflare Access policy allows one exact email/account and denies everyone else by default.
- [ ] Independent MFA is required.
- [ ] Access and MFA session durations are short and tested.
- [ ] T3 pairing URLs are never committed, logged in tickets, or shared in screenshots.
- [ ] Old T3 device sessions are revocable and audited periodically.
- [ ] `~/.codex/auth.json`, `~/.cli-proxy-api/`, the CLIProxyAPI local API key, Cloudflare tunnel credentials, and T3 secrets are never added to this repository.
- [ ] The public browser provider is run with the least practical agent filesystem/shell permissions. Compromise of this UI is equivalent to remote control of local coding agents.
- [ ] Cloudflare, T3, proxy, Codex CLI, Claude Code, and Node versions are recorded after installation for reproducibility.

## Open questions / live-test gates

- [ ] Does the ChatGPT subscription expose all four mapped GPT IDs through CLIProxyAPI today? Entitlement can vary by account and upstream rollout.
- [ ] Does Claude Code `2.1.215` display all four friendly mapped model names and the declared per-model effort capabilities behind the custom base URL?
- [ ] With both T3 providers sharing the normal Claude home, do `ANTHROPIC_AUTH_TOKEN`, the empty `ANTHROPIC_API_KEY`, and `ANTHROPIC_BASE_URL` reliably override the cached native Claude subscription only for the CLIProxyAPI provider?
- [ ] Does T3 permit provider switching on an existing thread when both Claude providers have the same empty Claude HOME path but different provider environment variables?
- [ ] Does the T3 Desktop-managed backend remain reachable from same-host `cloudflared` while Network access is off?
- [ ] Does the installed T3 release serve its web UI directly at the tunnel hostname, or is hosted `app.t3.codes` pairing required for this mode?
- [ ] Does hosted `app.t3.codes` work with the Access-protected cross-origin WebSocket in the target browsers?
- [ ] Does T3 discover the standalone Codex CLI from the GUI environment, or must its absolute path be configured?

## Sources

- [Claude `claudex` setup artifact supplied with the request](https://claude.ai/code/artifact/<TUNNEL_UUID>#no_universal_links) — reviewed from the user-supplied Markdown export; confirms the shared-home, invocation-scoped proxy pattern
- [Tibo's CLIProxyAPI/`claudex` post](https://x.com/thsottiaux/status/2076119366647894371) — supplied recipe and environment variables; the user also supplied the full post text because X retrieval was unreliable
- [CLIProxyAPI repository](https://github.com/router-for-me/CLIProxyAPI) — supported OAuth providers and Anthropic-compatible endpoint
- [CLIProxyAPI quick start](https://help.router-for.me/introduction/quick-start) — Homebrew installation, executable, service, and default config path
- [CLIProxyAPI basic configuration](https://help.router-for.me/configuration/basic) — loopback binding, port, management settings, auth directory, and local API keys
- [CLIProxyAPI Codex OAuth](https://help.router-for.me/configuration/provider/codex) — Codex login and browser callback flow
- [CLIProxyAPI Claude Code client](https://help.router-for.me/agent-client/claude-code) — `ANTHROPIC_BASE_URL`, client token, Claude Code v2 model variables, and model selection
- [OpenAI GPT-5.6 model guidance](https://developers.openai.com/api/docs/guides/latest-model) — Sol/Terra/Luna roles, model IDs, and effort levels
- [OpenAI GPT-5.4 mini model](https://developers.openai.com/api/docs/models/gpt-5.4-mini) — exact model ID, subagent/high-volume role, and supported effort levels
- [OpenAI Codex authentication](https://learn.chatgpt.com/docs/auth) — ChatGPT subscription login, API-key login, caching, and credential storage
- [OpenAI Codex CLI](https://learn.chatgpt.com/docs/codex/cli) — current standalone installation flow
- [OpenAI Codex plugin for Claude Code](https://github.com/openai/codex-plugin-cc) — native-Claude-orchestrator hybrid option
- [Claude Code custom subagents](https://code.claude.com/docs/en/sub-agents) — agent files, full model IDs, and `CLAUDE_CODE_SUBAGENT_MODEL` precedence
- [Claude Code model configuration](https://code.claude.com/docs/en/model-config) — Fable/Opus/Sonnet/Haiku aliases, custom display names, gateway model IDs, and per-model effort capabilities
- [Claude Code memory](https://code.claude.com/docs/en/memory) — shared `~/.claude/CLAUDE.md` behavior and importing `AGENTS.md`
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
