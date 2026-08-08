# Codex Web GPT Lifecycle Management

Add opt-in lifecycle management for the Codex Web GPT launcher and its Codex
route. The launcher remains the owner of its Bun daemon, browser helper, tunnel,
and shutdown transaction. CodeLaunch only manages the reversible route and, when
it started the launcher itself, requests a normal application quit.

## Decisions

- [x] Gate all behavior behind `CODEX_WEB_GPT_MANAGED=1`.
- [x] Use `codex-chatgpt-web route connect` and `route disconnect` for daily
  lifecycle changes.
- [x] Never run `codex-chatgpt-web uninstall` from `start.sh`, `stop.sh`, or
  `stop.sh --all`.
- [x] Never kill Bun, the tunnel runtime, browser helpers, or other supervised
  children directly.
- [x] Quit the app through its bundle identifier, as if the user chose Quit from
  the macOS menu:

  ```applescript
  tell application id "dev.codexwebgpt.launcher" to quit
  ```

- [x] Treat a missing or incomplete Codex Web GPT setup as a warning. It must not
  block the rest of CodeLaunch startup or shutdown.
- [x] Reuse a launcher that was already running without claiming ownership.
  CodeLaunch may manage the route, but it must only quit a launcher process that
  it started and recorded.
- [x] `stop.sh --all` must use the same safe Codex Web GPT behavior as normal
  stop. `--all` does not authorize uninstalling, force-killing, or stopping an
  unowned launcher.

## Environment and shared helpers

- [x] Add `CODEX_WEB_GPT_MANAGED` to `.env.example`, defaulting to `0`.
- [x] Add it to the allowlist in `scripts/env.sh` and accept only `0` or `1`.
- [x] Add helpers for:
  - locating the `codex-chatgpt-web` CLI through a documented, stable path;
  - reading and validating `route status` JSON;
  - finding the exact launcher process by bundle/executable identity;
  - recording launcher PID plus process start identity under
    `$HOME/.codelaunch/run/`;
  - rejecting symlinked, malformed, stale, or PID-recycled ownership records;
  - clearing the record only after the exact owned launcher exits.
- [x] Keep launcher ownership separate from route state. A pre-existing launcher
  is unowned even when CodeLaunch connects or disconnects the route.

Do not depend on a version-specific private runtime path such as
`~/.codex-chatgpt-web/versions/<version>/...` unless Codex Web GPT documents it
as a stable command entrypoint. Prefer a CLI on `PATH` or another launcher-owned
stable shim and document that prerequisite.

## Known gaps (found after implementation, not yet fixed)

- [x] CLI resolution did not match how the launcher ships on macOS.
  `install-launcher.sh` places only `Codex Web GPT.app`; the `~/.local/bin`
  wrapper it writes is the Linux branch and is the launcher, not the CLI. The
  bundle has no `Contents/Resources/runtime/bin/codex-chatgpt-web`, so that
  fallback in `codelaunch_codex_web_gpt_cli` was dead. Fixed with
  `codelaunch_codex_web_gpt_runtime_cli`, which reads `releaseVersion` from
  `$CODEX_CHATGPT_WEB_HOME`/`~/.codex-chatgpt-web/config.json` and resolves
  `versions/<version>-darwin-<arch>/bin/codex-chatgpt-web`, so launcher updates
  are picked up without touching PATH. An on-PATH CLI still wins if present. No
  manual symlink is needed and the docs no longer ask for one.
- [x] `codelaunch_codex_web_gpt_app_path` stalled when the launcher was not
  running. `osascript -e 'POSIX path of (path to application id ...)'` sends an
  AppleEvent to the target; with the app installed but stopped it ran for over a
  minute and then failed with `-1712 AppleEvent timed out`. That is the primary
  start path, so it stalled `start.sh` and `stop.sh` and then reported the app as
  missing. Replaced with a filesystem lookup over
  `$CODEX_WEB_GPT_APPLICATIONS_DIR`, `/Applications`, and `~/Applications`, then
  Spotlight, with `plutil` confirming `CFBundleIdentifier` on each candidate. No
  AppleEvent is sent and nothing is launched to answer the question.
- [x] A stale ownership record wedged both scripts instead of self-healing.
  `codelaunch_codex_web_gpt_owned_pid` returned 2 when the record was well-formed
  but its PID was dead or recycled, and never cleared it, so after a reboot,
  crash, or manual quit every `./start.sh` bailed with "invalid ownership record"
  before it could repair the route - leaving the journal active against a dead
  loopback daemon and native Codex broken until the file was deleted by hand.
  `stop.sh` had the same trap on the recycled-PID branch, which returned and kept
  the record forever. Now `owned_pid` clears a provably stale record and returns
  1 (not owned), exactly like `codelaunch_caffeinate_owned_pid`; rc 2 means only
  a malformed or symlinked record, and that warning now names the file to remove.
  `stop.sh` classifies both a dead and a recycled PID as stale and falls into the
  existing stale flow, which still refuses to signal anything and clears the
  record only once the launcher and its `/healthz` runtime are confirmed gone.
  Also fixed the quit-wait race: if the launcher exited between the loop's
  `kill -0` and the identity recheck, the recheck failure was reported as
  "PID identity changed during shutdown" and the record was retained even though
  the quit succeeded. The loop now rechecks liveness and breaks into the normal
  clean-exit path when the process is gone.

## Setup detection

- [x] First check whether lifecycle management is enabled. When disabled, do
  nothing and preserve current behavior exactly.
- [x] Check independently for:
  - the Codex Web GPT application bundle;
  - the `codex-chatgpt-web` CLI;
  - a readable integration journal through `route status`;
  - a consistent route state with no reported errors.
- [x] Use `route status`, not `uninstall` or setup commands, to determine whether
  the reversible Codex integration exists.
- [x] Use `doctor --json` only after the launcher is running when a full runtime
  health check is useful. A stopped runtime should not be mistaken for an
  unconfigured installation.
- [x] When installation or setup is missing, print one actionable warning:
  open the Codex Web GPT launcher, complete its setup, disable **Launch at
  login** if CodeLaunch should own startup, and rerun `./start.sh`.
- [x] Continue the remaining CodeLaunch operation after this warning.

## `start.sh`

Place this before the T3 backend is started so new T3 Codex sessions see the
intended route and model catalog.

- [x] Load `CODEX_WEB_GPT_MANAGED` with the other environment values.
- [x] If disabled, skip every Codex Web GPT check and action.
- [x] Run the nonfatal setup detection above.
- [x] If the launcher is already running:
  - verify the exact application identity;
  - reuse it without creating or replacing an ownership record.
- [x] Run `codex-chatgpt-web route connect` while the route is inactive, before
  opening a stopped launcher. The launcher starts its supervised runtime at
  process startup only when that route is already active, so connecting after
  the runtime is healthy would never bring a stopped runtime up.
- [x] Re-read `route status` and require `installed: true`, `active: true`, no
  errors, and the expected loopback route before opening the launcher.
- [x] If the launcher is absent:
  - launch it hidden/backgrounded with the packaged app;
  - resolve the resulting launcher PID;
  - verify PID, process start identity, executable path, and bundle identity;
  - write the ownership record only after verification succeeds.
- [x] Wait for the launcher-owned local runtime to become healthy. Use the
  configured route URL/port from Codex Web GPT state rather than hard-coding
  `17841` where practical.
- [x] Verify `doctor --json` and re-read `route status` with the same
  requirements before reporting success.
- [x] If launch, health verification, or route verification fails:
  - print a clear warning with the failed stage;
  - compensate with `route disconnect` when CodeLaunch connected the route or
    opened the launcher, so native Codex is not stranded on a dead loopback;
  - preserve any valid ownership record for later cleanup;
  - continue starting the rest of CodeLaunch;
  - never fall back to setup, uninstall, direct child-process startup, or force
    cleanup.

## `stop.sh`

Run this after T3 and other managed Codex consumers have been asked to stop, but
before the final Docker/caffeinate handling.

- [x] Load `CODEX_WEB_GPT_MANAGED` as an optional value so shutdown still works
  when `.env` is missing.
- [x] If disabled, skip every Codex Web GPT action.
- [x] If the CLI, app, or integration journal is missing, warn and continue the
  remaining shutdown.
- [x] Read `route status` before changing anything.
- [x] If the route is active, run `codex-chatgpt-web route disconnect`.
- [x] Verify afterward that the journal remains installed, the route is inactive,
  the prior Codex configuration was restored, and no integration errors are
  reported.
- [x] If route disconnection fails, leave the launcher running. Quitting it while
  Codex still points at its loopback daemon would break native Codex models.
  Report the problem and continue stopping unrelated CodeLaunch components.
- [x] After a verified disconnect, inspect the launcher ownership record:
  - owned and exact: request the AppleScript application quit;
  - running but unowned: leave it running and report that decision;
  - invalid/stale record: fail closed, leave the app running, and warn.
- [x] Allow roughly 60 seconds for the launcher to drain active work and exit.
- [x] Never escalate to `kill`, `kill -9`, `pkill`, direct Bun shutdown, or child
  cleanup when the app remains running.
- [x] If the launcher refuses to quit because work is active, retain the
  ownership record for a later retry and report that it remains running.
- [x] Clear ownership only after both the exact launcher process has exited and
  its local health endpoint is gone.
- [x] Make normal stop and `stop.sh --all` identical for Codex Web GPT. In
  particular, `--all` must not call `uninstall`.

## Documentation

- [x] Update `README.md` with a short note that T3 uses the normal Codex provider
  and can expose native plus `chatgpt-web/*` models through Codex Web GPT.
- [x] Add the full launcher setup and lifecycle behavior to `SETUP.md` as
  "Step 6 - Codex Web GPT (optional)", cross-linked from the Step 5 start and
  stop lists:
  - complete setup in the launcher first;
  - disable **Launch at login** when CodeLaunch should own app startup;
  - **Keep server running when window closes** may stay enabled because an
    application quit is different from closing the window;
  - while connected, native Codex models also traverse the local route;
  - stop restores the prior native route with `route disconnect`;
  - missing setup is nonfatal and produces a warning.
- [x] Document installing and updating the launcher with
  `install-launcher.sh` in `SETUP.md` and `QUICK-SETUP.md`, including that it
  refuses to overwrite a running launcher.
- [x] Document the `codex-chatgpt-web` PATH prerequisite in `SETUP.md` and
  `QUICK-SETUP.md`. The macOS installer places only the app bundle; the CLI
  exists only inside the private per-release runtime directory, so the symlink
  and the need to re-point it after an update are a documented setup step until
  CLI resolution is fixed below.
- [x] Update `QUICK-SETUP.md` with the `.env` switch and daily start/stop result.
- [x] Update `.t3/example.settings.json` and
  `.t3/example.client-settings.json` with minimal, portable Codex examples only.
  Do not copy personal UI settings or absolute user paths. The `codex` provider
  is now enabled with `binaryPath: "codex"`, plus one `chatgpt-web/high`
  favorite.
- [x] Add the installed Codex Web GPT and relevant Codex versions to
  `TOOL-VERSIONS.md`.
- [x] Document that `~/.codex-chatgpt-web` contains private authentication,
  runtime, and integration state and must not be committed.

## Manual verification matrix

- [ ] `CODEX_WEB_GPT_MANAGED=0`: start and both stop modes behave exactly as
  before.
- [ ] Enabled, app/CLI absent: start and stop warn but complete their unrelated
  work successfully.
- [ ] Enabled, installed but setup incomplete: warn with launcher setup guidance;
  do not invoke setup or uninstall automatically.
- [ ] Enabled, launcher already running: reuse it unowned, connect the route on
  start, disconnect the route on stop, and leave the app running.
- [ ] Enabled, launcher absent: start it hidden, validate and record ownership,
  then connect the route.
- [ ] Owned launcher, idle: stop disconnects the route, gracefully quits the app,
  waits for the daemon to disappear, and clears ownership.
- [ ] Owned launcher, active turn: no force kill; report the refusal and retain
  ownership for retry.
- [ ] Active route with stopped launcher: start repairs service availability;
  stop restores the prior native route without uninstalling.
- [ ] Route disconnect failure: launcher stays running and native routing is not
  knowingly stranded on a dead loopback endpoint.
- [ ] `stop.sh --all`: no invocation of `codex-chatgpt-web uninstall`, no direct
  Bun signal, and no unowned launcher quit.
- [ ] Repeated start/stop calls are idempotent and leave no stale ownership file.

## Done when

- [ ] The implementation follows CodeLaunch's existing ownership and fail-closed
  conventions.
- [ ] Native Codex works directly after stop because the prior route is restored.
- [ ] Native and web-backed Codex models work after start through the connected
  launcher route.
- [ ] Missing Codex Web GPT setup never blocks unrelated CodeLaunch lifecycle
  work.
- [ ] No normal or `--all` path can uninstall Codex Web GPT or directly kill its
  Bun runtime.
