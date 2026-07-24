# TODO

What's actually left. Full history lives in git (`git log TODO/TODO.md`, last
full version at commit `ed12e34`). The stack - CLIProxyAPI, claudex, T3,
Cloudflare Access + Tunnel - is built, tested, and in daily use from
off-network devices.

## Open

- [x] Verify `start.sh`'s headless path end to end: with the Desktop app fully
  quit, let the script start `t3 serve` and confirm remote pairing + streaming
  work the same. Verified: with Desktop quit, `start.sh` starts the headless
  `t3 serve` backend and remote pairing + streaming behave the same as the
  reuse path.
- [x] Pin the CLIProxyAPI image to a version tag or digest instead of
  `eceasy/cli-proxy-api:latest` (currently resolves to `v7.2.92`). Pinned by
  digest (`sha256:af18f6fb364bfb7b482a1ca6c6c85fd7df2c0d6a3a497ebb82c337ac2216dc41`,
  v7.2.92) since tags stay mutable upstream.

## Recurring

- [ ] After a `t3-code` cask auto-update: re-check the version, that the backend
  still binds `127.0.0.1:3773` only, and the Claude HOME field behavior noted in
  SETUP.md Step 3.
- [ ] Audit remote access occasionally: `t3 auth session list` /
  `t3 auth pairing list`, revoke anything stale. Skim the Cloudflare Access
  logs too.
- [ ] Codex OAuth token: `expired` in `cliproxy/auth/codex-*.json` lands ~10
  days after `last_refresh`. `start.sh` checks it and prompts. Re-login is
  on-host only (`./cliproxy/login.sh`, browser callback on `1455`).
- [ ] Keep the examples in sync with live config: `cliproxy/example.config.yaml`
  with `config.yaml`, `.t3/example.*.json` with `~/.t3/userdata/`.

## Settled (do not reopen)

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
