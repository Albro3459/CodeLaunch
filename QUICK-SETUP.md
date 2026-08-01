# Quick Setup

Day-to-day start/stop. Full docs: [SETUP.md](SETUP.md).

## One-time Mac prep

- Plug into power (required).
- System Settings -> General -> Sharing -> **Remote Login** ON.
- System Settings -> Battery -> Options -> **Wake for network access**: "Only on
  power adapter" is fine - the setting is per power source.
- Verify while plugged in: `pmset -g | grep womp` shows `1`. On battery it
  shows `0` - fine, since always-on needs AC anyway.

After that you can lock the screen and close the lid - tested. On battery, or
without `caffeinate`, it stops.

## Start

```bash
./start.sh            # 15m pairing token; interactive pairing helper
./start.sh 5m         # custom TTL
./start.sh --detached # print code and all pair URLs, then exit
./start.sh 5m -d      # TTL and detached mode may appear in either order
```

Normal `start.sh` and `t3-pair.sh` stay open in the pairing helper. They print a
numbered list beginning with the Tunnel URL; with `T3_BIND=all`, active VPN and
Wi-Fi addresses are included when available. Press `c`, enter a URL number, and
scan the selected QR. No QR is rendered before `c`. Press `q` to exit only the
pairing helper; services keep running. `-d`/`--detached` prints the code and all
URLs, then exits without reading input. Non-TTY runs automatically use detached
behavior. `qrencode` is optional.

For mobile app pairing over a trusted LAN or VPN, set `T3_BIND=all`. Direct
URLs use an explicit `http://` scheme and bypass Cloudflare Access, so use them
only on a trusted active VPN or Wi-Fi network. See
[SETUP.md](SETUP.md#4e-direct-lanvpn-pairing-required-for-the-mobile-app).

If the Codex sign-in has expired, `start.sh` opens the browser login first; otherwise it reuses the running services. It ensures the T3 backend matches `T3_BIND`, starts the tunnel, then mints the pairing token.

## Push notifications (optional)

Off by default. Enabling sends thread and project titles to `relay.t3.codes`, which
forwards to APNs - the one part of this stack that leaves infrastructure you control.
It does not use your tunnel, and no code or diffs are sent. See
[SETUP.md](SETUP.md#4f-publishing-agent-activity-push-notifications).

```bash
./t3-publish.sh              # one-time setup, headless OAuth (sign in from any device)
./t3-publish.sh --disable    # stop publishing, keep the sign-in
./t3-publish.sh --check-only # what is persisted on this machine
./t3-publish.sh --verify-only # whether the credential actually worked this boot
```

Then set `T3_PUBLISH_ACTIVITY=1` in `.env` and restart the stack. Setup state lives in
`~/.t3/userdata/secrets`, so it survives `stop.sh` and reboots - there is nothing to re-run.

`start.sh` checks the declared setting against what is persisted before bringing things
up, and after the tunnel checks whether the relay link actually reconciled this boot.
That second check matters: `npx t3 connect status` only reads local files, so it keeps
reporting "provisioned" from stale secrets long after the credential stopped working.

## Stop

```bash
./stop.sh             # tunnel, T3 backend, claudex sessions, proxy
./stop.sh --all       # also Docker Desktop and CodeLaunch-owned caffeinate
./stop.sh -a          # short form
```

Normal stop leaves Docker Desktop, native Claude Code, `caffeinate -dims`, and
unrelated T3 Connect relay connectors running. `start.sh` reuses an existing
caffeinate assertion; a pre-existing unowned assertion is reused but never
stopped. `--all` stops Docker Desktop and only the CodeLaunch-owned caffeinate,
after the proxy; it never stops native Claude Code, T3 Connect, unrelated
tunnels, or unrelated Docker containers.

## Useful

```bash
. ./scripts/env.sh
codelaunch_load_env T3_CHANNEL       # must match the desktop app
npx "t3@$T3_CHANNEL" auth session list      # active device sessions
npx "t3@$T3_CHANNEL" auth pairing list      # outstanding pairing tokens
npx "t3@$T3_CHANNEL" auth pairing revoke <id>   # kill one
./cliproxy/login.sh                  # manual Codex re-auth (on-host, browser)
```

Newly started processes log to `$HOME/.codelaunch/run/cloudflared-t3.log`
and `$HOME/.codelaunch/run/t3-serve.log` (private to your user). Existing
processes keep their current log files until you stop and restart them.
