# Quick Setup

Day-to-day start/stop. Full docs: `SETUP.md`.

## One-time Mac prep

- Plug into power (required).
- System Settings -> General -> Sharing -> **Remote Login** ON.
- System Settings -> Battery -> Options -> **Wake for network access**: "Only on
  power adapter" is fine — the setting is per power source.
- Verify while plugged in: `pmset -g | grep womp` shows `1` (reads `0` on battery
  by design; always-on requires AC anyway).

After that you can lock the screen and close the lid - tested. On battery, or
without `caffeinate`, it stops.

## Start

```bash
./start.sh            # 15m pairing token
./start.sh 5m         # custom TTL
```

Open the printed Pair URL (or paste the token) in a phone browser after passing
Cloudflare Access. If the Codex token is expired, `start.sh` auto-launches the
browser login first; otherwise it reuses everything.

## Stop

```bash
./stop.sh             # tunnel, T3 backend, claudex sessions, proxy, caffeinate
```

Leaves Docker Desktop and native Claude Code running.

## Useful

```bash
npx t3@nightly auth session list      # active device sessions
npx t3@nightly auth pairing list      # outstanding pairing tokens
npx t3@nightly auth pairing revoke <id>   # kill one
./cliproxy/login.sh                  # manual Codex re-auth (on-host, browser)
```

Logs: `/tmp/cloudflared-t3.log`, `/tmp/t3-serve.log`.
