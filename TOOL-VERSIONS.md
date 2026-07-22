# Tool versions

As tested and working together, recorded 2026-07-21.

| Tool | Version |
| --- | --- |
| macOS | 26.5 (build 25F71), Apple Silicon (arm64) |
| Docker Engine | 28.3.2 (build 578ccf6) |
| Docker Compose | v2.39.1-desktop.1 |
| CLIProxyAPI | v7.2.92 (`eceasy/cli-proxy-api:latest`) |
| cloudflared | 2026.7.2 (built 2026-07-15) |
| Claude Code | 2.1.217 |
| T3 Code Desktop | 0.0.29-nightly.20260721.864 (`T3 Code (Nightly).app`, cask `t3-code`) |
| t3 CLI (`npx t3@nightly`) | 0.0.29-nightly.20260722.877 |
| Node | v24.18.0 |
| npm | 11.16.0 |

Notes:

- The CLI is pinned to the `nightly` dist-tag to match the desktop cask; `latest`
  trails it (`0.0.28`). Both share the `~/.t3` store and the CLI migrates its
  schema, so channels are kept aligned. Nightly moves daily — the version above
  is whatever `npm view t3 dist-tags` returned when recorded.
- The `t3-code` cask auto-updates; re-record its version (and re-check the
  backend port/binding) after updates.
- CLIProxyAPI is pinned only by `latest` today; see TODO for pinning to a
  digest.
