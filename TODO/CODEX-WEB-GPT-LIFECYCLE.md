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

- [ ] Add `CODEX_WEB_GPT_MANAGED` to `.env.example`, defaulting to `0`.
- [ ] Add it to the allowlist in `scripts/env.sh` and accept only `0` or `1`.
- [ ] Add helpers for:
  - locating the `codex-chatgpt-web` CLI through a documented, stable path;
  - reading and validating `route status` JSON;
  - finding the exact launcher process by bundle/executable identity;
  - recording launcher PID plus process start identity under
    `$HOME/.codelaunch/run/`;
  - rejecting symlinked, malformed, stale, or PID-recycled ownership records;
  - clearing the record only after the exact owned launcher exits.
- [ ] Keep launcher ownership separate from route state. A pre-existing launcher
  is unowned even when CodeLaunch connects or disconnects the route.

Do not depend on a version-specific private runtime path such as
`~/.codex-chatgpt-web/versions/<version>/...` unless Codex Web GPT documents it
as a stable command entrypoint. Prefer a CLI on `PATH` or another launcher-owned
stable shim and document that prerequisite.

## Setup detection

- [ ] First check whether lifecycle management is enabled. When disabled, do
  nothing and preserve current behavior exactly.
- [ ] Check independently for:
  - the Codex Web GPT application bundle;
  - the `codex-chatgpt-web` CLI;
  - a readable integration journal through `route status`;
  - a consistent route state with no reported errors.
- [ ] Use `route status`, not `uninstall` or setup commands, to determine whether
  the reversible Codex integration exists.
- [ ] Use `doctor --json` only after the launcher is running when a full runtime
  health check is useful. A stopped runtime should not be mistaken for an
  unconfigured installation.
- [ ] When installation or setup is missing, print one actionable warning:
  open the Codex Web GPT launcher, complete its setup, disable **Launch at
  login** if CodeLaunch should own startup, and rerun `./start.sh`.
- [ ] Continue the remaining CodeLaunch operation after this warning.

## `start.sh`

Place this before the T3 backend is started so new T3 Codex sessions see the
intended route and model catalog.

- [ ] Load `CODEX_WEB_GPT_MANAGED` with the other environment values.
- [ ] If disabled, skip every Codex Web GPT check and action.
- [ ] Run the nonfatal setup detection above.
- [ ] If the launcher is already running:
  - verify the exact application identity;
  - reuse it without creating or replacing an ownership record.
- [ ] If the launcher is absent:
  - launch it hidden/backgrounded with the packaged app;
  - resolve the resulting launcher PID;
  - verify PID, process start identity, executable path, and bundle identity;
  - write the ownership record only after verification succeeds.
- [ ] Wait for the launcher-owned local runtime to become healthy. Use the
  configured route URL/port from Codex Web GPT state rather than hard-coding
  `17841` where practical.
- [ ] Run `codex-chatgpt-web route connect` only after the runtime is healthy.
- [ ] Re-read `route status` and require `installed: true`, `active: true`, no
  errors, and the expected loopback route before reporting success.
- [ ] If launch, health verification, or route connection fails:
  - print a clear warning with the failed stage;
  - preserve any valid ownership record for later cleanup;
  - continue starting the rest of CodeLaunch;
  - never fall back to setup, uninstall, direct child-process startup, or force
    cleanup.

## `stop.sh`

Run this after T3 and other managed Codex consumers have been asked to stop, but
before the final Docker/caffeinate handling.

- [ ] Load `CODEX_WEB_GPT_MANAGED` as an optional value so shutdown still works
  when `.env` is missing.
- [ ] If disabled, skip every Codex Web GPT action.
- [ ] If the CLI, app, or integration journal is missing, warn and continue the
  remaining shutdown.
- [ ] Read `route status` before changing anything.
- [ ] If the route is active, run `codex-chatgpt-web route disconnect`.
- [ ] Verify afterward that the journal remains installed, the route is inactive,
  the prior Codex configuration was restored, and no integration errors are
  reported.
- [ ] If route disconnection fails, leave the launcher running. Quitting it while
  Codex still points at its loopback daemon would break native Codex models.
  Report the problem and continue stopping unrelated CodeLaunch components.
- [ ] After a verified disconnect, inspect the launcher ownership record:
  - owned and exact: request the AppleScript application quit;
  - running but unowned: leave it running and report that decision;
  - invalid/stale record: fail closed, leave the app running, and warn.
- [ ] Allow roughly 60 seconds for the launcher to drain active work and exit.
- [ ] Never escalate to `kill`, `kill -9`, `pkill`, direct Bun shutdown, or child
  cleanup when the app remains running.
- [ ] If the launcher refuses to quit because work is active, retain the
  ownership record for a later retry and report that it remains running.
- [ ] Clear ownership only after both the exact launcher process has exited and
  its local health endpoint is gone.
- [ ] Make normal stop and `stop.sh --all` identical for Codex Web GPT. In
  particular, `--all` must not call `uninstall`.

## Documentation

- [ ] Update `README.md` with a short note that T3 uses the normal Codex provider
  and can expose native plus `chatgpt-web/*` models through Codex Web GPT.
- [ ] Add the full launcher setup and lifecycle behavior to `SETUP.md`:
  - complete setup in the launcher first;
  - disable **Launch at login** when CodeLaunch should own app startup;
  - **Keep server running when window closes** may stay enabled because an
    application quit is different from closing the window;
  - while connected, native Codex models also traverse the local route;
  - stop restores the prior native route with `route disconnect`;
  - missing setup is nonfatal and produces a warning.
- [ ] Update `QUICK-SETUP.md` with the `.env` switch and daily start/stop result.
- [ ] Update `.t3/example.settings.json` and
  `.t3/example.client-settings.json` with minimal, portable Codex examples only.
  Do not copy personal UI settings or absolute user paths.
- [ ] Add the installed Codex Web GPT and relevant Codex versions to
  `TOOL-VERSIONS.md`.
- [ ] Document that `~/.codex-chatgpt-web` contains private authentication,
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
