# Tool versions

As tested and working together, recorded 2026-07-22.

| Tool | Version |
| --- | --- |
| macOS | 26.5 (build 25F71), Apple Silicon (arm64) |
| Docker Engine | 28.3.2 (build 578ccf6) |
| Docker Compose | v2.39.1-desktop.1 |
| CLIProxyAPI | v7.2.92, commit 53c1e7e, built 2026-07-20 (pinned by digest `sha256:af18f6fb364bfb7b482a1ca6c6c85fd7df2c0d6a3a497ebb82c337ac2216dc41`) |
| cloudflared | 2026.7.2 (built 2026-07-15) |
| Claude Code | 2.1.217 |
| T3 Code Desktop | 0.0.29-nightly.20260721.864 (`T3 Code (Nightly).app`, cask `t3-code@nightly`) |
| t3 CLI (`npx t3@$T3_CHANNEL`) | 0.0.28 (`latest`) / 0.0.29-nightly.20260722.877 (`nightly`) |
| Node | v24.18.0 |
| npm | 11.16.0 |
| jq | 1.8.1 |
| qrencode | 4.1.1 |

Notes:

- The CLI dist-tag comes from `T3_CHANNEL` in `.env` and must match the
  installed desktop app - `start.sh` and `t3-pair.sh` enforce this since both
  sides share the `~/.t3` store and the CLI migrates its schema. Nightly moves
  daily, so versions above are whatever `npm view t3 dist-tags` returned when
  recorded.
- The `t3-code` cask auto-updates. Re-record its version (and re-check the
  backend port/binding) after updates.
- CLIProxyAPI is pinned by digest in `cliproxy/docker-compose.yml` since tags
  are mutable and could change routing behavior on a pull. To move: pull the
  new image, re-verify `/v1/models` and effort, update the digest and version
  together, and check the running build with
  `docker exec cliproxyapi ./CLIProxyAPI --version`.
