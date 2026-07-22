# README

Local Agent Setup (Codex to Claude Code w/ [CLIProxyAPI](https://github.com/router-for-me/CLIProxyAPI), [T3 Code](https://github.com/pingdotgg/t3code/tree/main/apps/desktop) + remote over https w/ Cloudflare Tunnel)

Tested and working on an ARM Mac (Apple Silicon, macOS 26.x): the full remote
flow — Cloudflare Access + Tunnel -> T3 web -> claudex -> CLIProxyAPI -> Codex —
verified end to end from off-network devices, including a phone. Exact versions
in `TOOL-VERSIONS.md`; day-to-day start/stop in `QUICK-SETUP.md`; full build
docs in `SETUP.md`.