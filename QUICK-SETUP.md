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
./start.sh            # 15m pairing token
./start.sh 5m         # custom TTL
```

Either open the Pair URL, navigate to your URL directly and paste the token, or scan the QR code with a phone camera.

If the Codex sign-in has expired, `start.sh` opens the browser login first, otherwise it reuses the running services.

## Stop

```bash
./stop.sh             # tunnel, T3 backend, claudex sessions, proxy, caffeinate
```

Leaves Docker Desktop and native Claude Code running.

## Useful

```bash
. ./.env                             # T3_CHANNEL must match the desktop app
npx "t3@$T3_CHANNEL" auth session list      # active device sessions
npx "t3@$T3_CHANNEL" auth pairing list      # outstanding pairing tokens
npx "t3@$T3_CHANNEL" auth pairing revoke <id>   # kill one
./cliproxy/login.sh                  # manual Codex re-auth (on-host, browser)
```

Logs: `/tmp/cloudflared-t3.log`, `/tmp/t3-serve.log`.
