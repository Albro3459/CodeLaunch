# Quick Setup

Day-to-day start and stop. Full docs: [SETUP.md](SETUP.md).

## One-time Mac prep

- Plug into power. Required.
- System Settings -> General -> Sharing -> **Remote Login** on.
- System Settings -> Battery -> Options -> **Wake for network access**: "Only on
  power adapter" is fine.
- Check it while plugged in: `pmset -g | grep womp` shows `1`.

Then you can lock the screen and close the lid. On battery it stops.

## Start

```bash
./start.sh
```

Reuses anything already running, then prints a pairing code and a numbered list of
URLs. Press `c` and pick a number to show that QR, `q` to leave the helper without
stopping anything. Pass a TTL like `5m` to change the 15 minute default, or `-d` to
print the code and exit instead. Without a terminal it exits on its own.

If the Codex sign-in expired, it opens the browser login first.

For the mobile app, set `T3_BIND=all` in `.env` to also get direct LAN and VPN URLs.
Those skip Cloudflare Access, so only use them on a network you trust.
[More](SETUP.md#4e-direct-lanvpn-pairing-required-for-the-mobile-app).

## Stop

```bash
./stop.sh
```

Stops the tunnel, T3 backend, claudex sessions, and proxy. Leaves Docker Desktop,
native Claude Code, and `caffeinate` up. Pass `--all` to also stop Docker Desktop and
the caffeinate this repo started. It never touches anything it did not start.

## Push notifications

Off by default. Turning it on sends thread and project titles to `relay.t3.codes`,
which forwards them to your phone. No code or diffs, and it does not use your tunnel.
This is the only part of the stack that sends anything off your machine.
[More](SETUP.md#4f-publishing-agent-activity-push-notifications).

```bash
./t3-publish.sh
```

Signs you in from any device with a browser, then links this machine. Set
`T3_PUBLISH_ACTIVITY=1` in `.env` and restart. Pass `--disable` to stop publishing
without signing out.

Setup survives `stop.sh` and reboots, so there is nothing to re-run. `start.sh` checks
it twice: against `.env` before starting, then after the tunnel to see whether the link
actually worked this boot. The second check exists because `t3 connect status` only
reads local files, so it keeps reporting success long after the credential stopped
working.

## Codex Web GPT

Off by default. Adds the `chatgpt-web/*` models to the Codex provider in T3, on top
of the normal Codex ones. Install or update the launcher with:

```bash
curl -fsSL https://github.com/miuuyy/codex-chatgpt-web/releases/latest/download/install-launcher.sh | sh
```

Quit the app first when updating - the script will not overwrite a running launcher.
Then finish setup in the app. Nothing goes on your PATH; CodeLaunch finds the CLI
itself and keeps finding it across updates.

Set `CODEX_WEB_GPT_MANAGED=1` in `.env`. After that, `start.sh` points Codex at the
launcher and opens it hidden if it is not already running; `stop.sh` points Codex back
and quits the launcher only if it started it. Turn off **Launch at login** in the app
if you want `start.sh` to own that.

If the app is missing or its setup is incomplete, both scripts print a warning and
carry on. [More](SETUP.md#step-6---codex-web-gpt-optional).

## Useful

```bash
. ./scripts/env.sh
codelaunch_load_env T3_CHANNEL       # must match the desktop app
npx "t3@$T3_CHANNEL" auth session list      # active device sessions
npx "t3@$T3_CHANNEL" auth pairing list      # outstanding pairing tokens
npx "t3@$T3_CHANNEL" auth pairing revoke <id>   # kill one
./cliproxy/login.sh                  # manual Codex re-auth (on-host, browser)
```

Logs saved in `$HOME/.codelaunch/run/`.