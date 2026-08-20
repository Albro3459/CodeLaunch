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

The example T3 settings keep the native `codex` provider enabled. Before using
normal Codex models, quit the **ChatGPT** desktop app so T3 Code can own its
Codex app-server processes. CodeLaunch checks this and warns without quitting
the app for you. To quit it gracefully:

```bash
osascript -e 'tell application "ChatGPT" to quit'
```

If you need to diagnose a conflict, inspect the relevant processes with:

```bash
ps -ax -o pid,ppid,command | grep -E 'ChatGPT.app./codex|codex-code-mode-host'
```

```bash
./start.sh
```

Reuses anything already running. Runs the Claudex path if `CLAUDEX_ENABLED=1` (off by
default), then calls `./t3-start.sh` if `T3_ENABLED=1` (on by default), which owns the
whole T3 lifecycle. A TTL like `5m` (default 15m) and `-d`/`--detached` are passed
through to `t3-start.sh`; both are ignored in connect mode.

If Claudex is enabled and the Codex sign-in expired, it opens the browser login first.

**`T3_MODE=connect` (default):** checks `t3 connect status`, signs in and links this
environment if needed, starts the server, then tells you to sign in from any device -
no pairing code, tunnel, or hostname involved:

```
https://app.t3.codes
the T3 Code app on iOS
```

**`T3_MODE=custom`:** prints a pairing code and a numbered list of URLs instead. Press
`c` and pick a number to show that QR, `q` to leave the helper without stopping
anything. With `T3_CUSTOM_ACCESS=full` the URLs go through Cloudflare Access at
`T3_HOSTNAME`. With `T3_CUSTOM_ACCESS=direct` they point at this machine
(`http://127.0.0.1:$T3_PORT`), plus LAN/Wi-Fi and VPN addresses when `T3_BIND=all`.
**`T3_BIND=all` is not VPN-only: every device that can route to this machine,
including everything else on your Wi-Fi, can reach the port - the pairing code is the
only gate.** [More on modes](SETUP.md#modes),
[more on direct LAN/VPN pairing](SETUP.md#4e-direct-lanvpn-pairing-required-for-the-mobile-app).

## Stop

```bash
./stop.sh
```

Delegates the T3 server and any tunnel it started to `./t3-stop.sh`, which stops only
what it recorded as CodeLaunch-owned - a T3 Desktop app or a server you started
yourself is reported and left running, and T3 sign-in and the T3 Connect link are
never touched. Then stops claudex sessions, Codex Web GPT (if managed), and the
proxy. Leaves Docker Desktop, native Claude Code, and `caffeinate` up. Pass `--all`
to also stop Docker Desktop and the caffeinate this repo started. `./stop.sh t3` runs
`./t3-stop.sh` plus claudex sessions, nothing else.

After running `/login` in Claude Code or refreshing another CLI account, restart
only the T3 backend (and, in `T3_CUSTOM_ACCESS=full`, its tunnel) so it reloads the
account without interrupting the Claudex proxy:

```bash
./t3-restart.sh
```

This is equivalent to `./stop.sh t3 && ./t3-start.sh`.

## Push notifications

`T3_MODE=custom` only, off by default. Turning it on sends thread and project titles
to `relay.t3.codes`, which forwards them to your phone. No code or diffs, and it does
not use your tunnel. This is the only part of the stack that sends anything off your
machine. `T3_MODE=connect` ignores `T3_PUBLISH_ACTIVITY` entirely - the full T3
Connect link already publishes agent activity.
[More](SETUP.md#4f-publishing-agent-activity-push-notifications).

```bash
./t3-publish.sh
```

Custom mode: signs you in from any device with a browser, then links this machine.
Set `T3_PUBLISH_ACTIVITY=1` in `.env` and restart with `./t3-stop.sh && ./t3-start.sh`.
Connect mode: `--check-only` reports that publishing is managed by T3 Connect,
`--verify-only` is a no-op, and setup refuses - there is no publish-only link to set
up in that mode. `--disable` works in both modes without signing out.

Setup survives `stop.sh` and reboots, so there is nothing to re-run. In custom mode,
`t3-start.sh` checks it twice: against `.env` before starting the backend, then once
the backend (and the tunnel, in `full`) is up, to see whether the link actually worked
this boot. The second check exists
because `t3 connect status` only reads local files, so it keeps reporting success long
after the credential stopped working.

## Codex Web GPT

Off by default. When enabled, `start.sh` can start the Web GPT service headlessly
for the **ChatGPT** desktop integration. It requires the ChatGPT desktop app and
is not a usable provider inside T3 Code/CodeLaunch: Web GPT models cannot make
tool calls there. Install or update the launcher with:

```bash
curl -fsSL https://github.com/miuuyy/codex-chatgpt-web/releases/latest/download/install-launcher.sh | sh
```

Quit the app first when updating - the script will not overwrite a running launcher.
Then finish setup in the app. Nothing goes on your PATH; CodeLaunch finds the CLI
itself and keeps finding it across updates.

Set `CODEX_WEB_GPT_MANAGED=1` in `.env`. This requires `CLAUDEX_ENABLED=1` - it is
ignored (with a note) while `CLAUDEX_ENABLED=0`. After that, `start.sh` checks that
the ChatGPT desktop app is running and starts the service headlessly if needed;
`stop.sh` restores the native route and quits only a launcher it started itself.
This mode is for ChatGPT desktop integration, not T3 model use. Turn off **Launch
at login** in the app if you want `start.sh` to own launcher startup.

If the app is missing or its setup is incomplete, both scripts print a warning and
carry on. [More](SETUP.md#step-6---codex-web-gpt-optional).

## Useful

```bash
./t3-start.sh                        # start/reuse T3 alone, any mode
./t3-stop.sh                         # stop only the T3 server + tunnel CodeLaunch owns
. ./scripts/env.sh
codelaunch_load_env T3_CHANNEL       # must match the desktop app
npx "t3@$T3_CHANNEL" auth session list      # active device sessions
npx "t3@$T3_CHANNEL" auth pairing list      # outstanding pairing tokens
npx "t3@$T3_CHANNEL" auth pairing revoke <id>   # kill one
./cliproxy/login.sh                  # manual Codex re-auth (on-host, browser)
```

Logs saved in `$HOME/.codelaunch/run/`.
