# TODO

What's actually left. Full history lives in git (`git log TODO/TODO.md`, last
full version at commit `ed12e34`). The stack - CLIProxyAPI, claudex, T3,
Cloudflare Access + Tunnel - is built, tested, and in daily use from
off-network devices.

## Open

Nothing open.

## Recurring

- [ ] After a `t3-code` cask auto-update: re-check the version, that the backend
  still binds `127.0.0.1:3773` only, and the Claude HOME field behavior noted in
  SETUP.md Step 3. In connect mode also re-check that `t3 connect`'s
  login/link/unlink/status subcommands and the `cloud-cli-desired-link` secret
  still behave the way `t3-start.sh` reconciles against.
- [ ] Audit remote access occasionally: `t3 auth session list` /
  `t3 auth pairing list`, revoke anything stale. Skim the Cloudflare Access
  logs too.
- [ ] Codex OAuth token: `expired` in `cliproxy/auth/codex-*.json` lands ~10
  days after `last_refresh`. `start.sh` checks it and prompts. Re-login is
  on-host only (`./cliproxy/login.sh`, browser callback on `1455`).
- [ ] Track Codex Web GPT releases: after a launcher update, re-check that the
  CLI still resolves through `~/.codex-chatgpt-web/config.json` ->
  `versions/<version>-darwin-<arch>/bin/codex-chatgpt-web`, and that
  `route connect`/`route disconnect` still behave as `start.sh`/`stop.sh`
  expect. Never call `uninstall`.
- [ ] Keep the examples in sync with live config: `cliproxy/example.config.yaml`
  with `config.yaml`, `.t3/example.*.json` with `~/.t3/userdata/`.

## Settled (do not reopen)

- The `a42e4ef` T3 Connect review is closed: five fixes applied, both open
  questions decided. `t3-restart.sh` is meant to mint a fresh token and show the
  QR in custom mode. Details in
  [T3-CONNECT-REVIEW.md](T3-CONNECT-REVIEW.md).
- Codex Web GPT launcher lifecycle is done and tested: `start.sh`/`stop.sh` use
  opt-in, reversible `route connect`/`route disconnect`, only ever stop a
  launcher they started, and never uninstall. Details in git
  (`git log -- TODO/CODEX-WEB-GPT-LIFECYCLE.md`).
- Default model is the `opus` role = GPT-5.6 Luna, enforced by the `claudex`
  wrapper (`ANTHROPIC_MODEL=opus`). `~/.claudex/settings.json` now matches
  (`"model": "opus"`, no `effortLevel`).
- MFA is the Cloudflare account's own 2FA via the built-in Cloudflare IdP
  (restricted to account members, pinned to one email). No Independent MFA, no
  OTP. Tested: a different Cloudflare account is refused.
- T3 Desktop **Network access** stays "Limited to this machine". The tunnel
  connects over loopback and pairing tokens come from the CLI.
- CLIProxyAPI runs in Docker only. No Homebrew-native install.
- Always-on = plugged in + `caffeinate -dims` + Remote Login + Wake for network
  access (see QUICK-SETUP.md). Tested: survives lock and lid close on power.
