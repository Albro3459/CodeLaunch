# T3 Connect Implementation Review

Review of commit `a42e4ef` ("Implementation for T3 Connect support") against
[T3-CONNECT-MODES.md](T3-CONNECT-MODES.md) and the shipped docs. Covers
`t3-start.sh`, `t3-stop.sh`, `t3-pair.sh`, `t3-publish.sh`, `t3-restart.sh`,
`scripts/env.sh`, `scripts/pairing.sh`, `start.sh`, `stop.sh`, and the doc set.

Fixes below are applied but uncommitted.

## Fixed

- **Ownership globals never reached the caller.** `t3-start.sh` and `t3-stop.sh`
  both ran `owned_pid=$(codelaunch_t3_owned_pid)` and then read
  `$CODELAUNCH_T3_MODE`. The function sets its globals inside the `$( )`
  subshell, so under `set -u` the next line aborted with *unbound variable*.
  This broke the reuse path on a second `./t3-start.sh` and **every**
  `./t3-stop.sh` against an owned server - the two paths not exercised
  end-to-end before the commit. Both call sites now call the function directly
  and take the PID from `$CODELAUNCH_T3_PID`
  (`t3-start.sh:89`, `t3-stop.sh:36`). Verified with a scratch-`HOME` smoke test
  over the owned / not-owned / corrupt-record branches.

  The distinction that matters: `$( )` around one of these helpers is fine as
  long as the caller uses only the PID it prints. `start.sh:182` does exactly
  that with `codelaunch_codex_web_gpt_owned_pid` and is correct. It is reading a
  `CODELAUNCH_*` global *after* the subshell that breaks, which is what both T3
  call sites did. `stop.sh:123` shows the other safe shape - call
  `codelaunch_codex_web_gpt_record_pid` directly, then read the global.
  `codelaunch_t3_owned_pid`'s contract comment in `scripts/env.sh:484` now spells
  this out at the source, since the trap is not obvious at the call site.

  Blast radius while it was live: `stop.sh:50` calls `./t3-stop.sh` unguarded, so
  the abort took `./stop.sh` down with it and skipped claudex sessions, Codex Web
  GPT, the proxy, Docker Desktop, and caffeinate. `t3-restart.sh` failed the same
  way, in exactly the post-auth-refresh case it exists for.

- **`start.sh` always forwarded a TTL nobody asked for.** It passed the default
  `15m` to `t3-start.sh` unconditionally, so connect mode - the new default -
  printed "pairing options are ignored" on every ordinary start. It now forwards
  only options the caller actually passed (`start.sh:368`). Empty-array
  expansion is guarded for bash 3.2 and syntax-checked against `/bin/bash`.

- **Bind-mismatch refusal only told half the story.** `t3-pair.sh` printed the
  restart command for `T3_BIND=all` with nothing on the wildcard address, but
  the opposite case - `T3_BIND=loopback` with a wider bind - just said "Fix
  before pairing". `SETUP.md:776` claims the script asks you to restart a
  backend started with the other mode, which was true in one direction only.
  Both branches now print the restart command (`t3-pair.sh:154`).

- **Mode table overstated direct reach.** T3-CONNECT-MODES.md listed custom
  direct/full access as "Localhost, LAN/Wi-Fi, and VPN" with no bind qualifier,
  while `T3_BIND` defaults to `loopback` and `SETUP.md:33` carries the
  `T3_BIND=all` qualifier. Table rows now match SETUP.md.

- **`stop.sh` aborted the whole teardown when `t3-stop.sh` failed.** Step (b) was
  a bare `./t3-stop.sh` under `set -e`, so a nonzero child took `stop.sh` down
  with it and steps c-f never ran - claudex sessions, Codex Web GPT, the proxy,
  Docker Desktop, and caffeinate all left up, with no closing summary. Every
  other step in the file warns and continues, as its own header comment says. It
  now warns, finishes the teardown, and carries the child's status to the exit
  (`stop.sh:54`, `:73`, and the last line), so `t3-restart.sh`'s `&&` still sees
  a failed stop rather than restarting into a server that never died. Plain
  `|| true` was rejected for losing exactly that signal. Smoke-tested against a
  child exiting 0, a child exiting 3, and a child aborting on an unbound variable
  under `set -u` - the A1 class above, and the only way this fires today, since
  `t3-stop.sh` has no nonzero exit in its own teardown paths.

## Settled

- **`t3-restart.sh` minting a fresh pairing token in custom mode is intended.**
  It was `./stop.sh t3 && ./t3-pair.sh --ensure-only` (quiet, no new token); it
  is now `./stop.sh t3 && ./t3-start.sh`, which always reaches the token step
  (`t3-start.sh:307`) and at a TTY shows the `[c] show QR [q] quit` prompt in
  `scripts/pairing.sh`. Confirmed as wanted: a credential-refresh restart should
  hand you a new token and the QR. Non-interactively it auto-detaches, so
  automation is not blocked, and connect mode never reaches pairing at all - it
  exits at `t3-start.sh:227`. `SETUP.md:988` and `QUICK-SETUP.md:81` already
  document the new form. Do not reinstate `--ensure-only`.

## Verified, no action

- Docs match the code. The env-var allowlist (`scripts/env.sh:15`) covers
  `.env.example` with no undocumented vars, documented defaults match the
  scripts, command invocations and flags match each `usage()`, and the only
  remaining `t3-serve.sh` reference is the one in T3-CONNECT-MODES.md marking it
  removed.
- Mode refusals are correct. `t3-pair.sh:59` refuses under `T3_MODE=connect`
  before doing anything else, and `t3-publish.sh:57` reports connect-mode
  publishing as T3-managed rather than creating a second link. Defaults
  (`T3_MODE=connect`, `T3_CUSTOM_ACCESS=direct`) agree across all three scripts.
- The channel guard still runs on both paths - directly at `t3-start.sh:110` in
  connect mode, and on the custom path via `./t3-pair.sh --check-only`
  (`t3-start.sh:257` -> `t3-pair.sh:111`). The move into `scripts/env.sh:355` is
  behaviorally equivalent to the old inline check.
- Process safety improved. `t3-stop.sh` only signals a PID matching the recorded
  identity and command (`codelaunch_t3_state_matches`, `scripts/env.sh:474`),
  which is stricter than the old port-owner heuristic and cannot reach T3 Desktop
  or a user-started server.
- `./stop.sh t3` now also stops the CodeLaunch-owned tunnel, which previously
  survived a T3-only stop. Real change, documented at `stop.sh:3` and in
  SETUP.md, consistent with the new module boundary.
- The author's three judgment calls hold: the log markers exist in the shipped
  `bin.mjs`, `cloud-cli-desired-link.bin` really is a 7-byte plaintext `managed`,
  and the `npm exec` -> `node ... t3 serve` parent/child shape matches what
  `codelaunch_t3_server_child_pids` and `codelaunch_t3_unowned_pids` assume.
- `scripts/env.sh` is purely additive - no shared-helper regressions. Dropping
  `export T3_SERVE_LOG` from `start.sh` is safe because `t3-publish.sh:153`
  derives it itself.

## Not covered

Static review plus targeted smoke tests only. Nothing here replaces the SSH
detached-start/stop check still open in [TODO.md](TODO.md), which is the one
requirement in T3-CONNECT-MODES.md that a read of the code cannot settle.
