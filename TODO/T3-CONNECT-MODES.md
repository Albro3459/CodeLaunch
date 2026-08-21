# T3 Connect and Custom Startup Modes

Replace the current always-on Claudex/Cloudflare stack with independently
controlled Claudex and T3 lifecycles. The default startup should run only T3
through T3 Connect.

## Configuration

```sh
CLAUDEX_ENABLED=0

T3_ENABLED=1
T3_MODE=connect              # connect | custom
T3_CUSTOM_ACCESS=direct      # direct | full; used only in custom mode
T3_PUBLISH_ACTIVITY=0        # used only in custom mode
T3_CHANNEL=latest
```

`T3_ENABLED` controls whether `start.sh` starts T3. It is enabled by default.
`T3_MODE` selects T3 Connect or the existing custom hosting path; it does not
have an `off` value.

`CLAUDEX_ENABLED=0` must skip the Claudex path, including Docker,
CLIProxyAPI, Claudex prerequisites, and the Codex token checks needed by that
path. The existing `CODEX_WEB_GPT_MANAGED` setting remains subordinate to the
Claudex path.

## Mode behavior

| Configuration | T3 server | Direct access | T3-managed connection | Cloudflare tunnel | Activity publishing |
| --- | --- | --- | --- | --- | --- |
| `T3_ENABLED=0` | Off | Off | Off | Off | Off |
| `T3_MODE=connect` | On | Managed by T3 | On | Off | Managed by T3 Connect |
| `T3_MODE=custom`, `T3_CUSTOM_ACCESS=direct` | On | Localhost, plus LAN/Wi-Fi and VPN with `T3_BIND=all` | Off | Off | Optional |
| `T3_MODE=custom`, `T3_CUSTOM_ACCESS=full` | On | Localhost, plus LAN/Wi-Fi and VPN with `T3_BIND=all` | Off | On | Optional |

### Connect

Connect mode delegates remote access to T3 Connect. CodeLaunch should:

1. Check `npx --yes t3@$T3_CHANNEL connect status`.
2. Reconcile authentication and the environment link when setup is incomplete.
3. Replace an explicitly detected publish-only link with a full Connect link
   when necessary. Do not unlink merely because a generic status command
   failed.
4. Start `npx --yes t3@$T3_CHANNEL serve` detached from the invoking shell.
5. Tell the user to sign in through `app.t3.codes` or the T3 Code iOS app.

Connect mode must not validate, export, or pass the custom networking
configuration. This includes the hostname, port, bind setting, publish-only
setting, tunnel name, access email, and Cloudflare team. It must not start
`cloudflared`, generate custom tunnel URLs, or mint CodeLaunch pairing QR
codes.

The implementation should verify the current CLI's exact login, link, unlink,
start, and stop commands before encoding the reconciliation flow.

### Custom/direct

Direct mode serves T3 without a managed T3 connection or a Cloudflare tunnel.
The server binds for direct access from localhost and the machine's other
interfaces, including LAN/Wi-Fi and a VPN when present.

This is not VPN-only exposure. Documentation and startup output must warn that
other devices on the local network may also be able to reach the T3 port.

Cloudflare-only variables such as the public hostname, tunnel name, access
email, and Cloudflare team are ignored in this mode. The custom T3 port and
bind behavior still apply.

### Custom/full

Full mode preserves the current custom setup: serve T3 directly and run the
existing custom Cloudflare Access/Tunnel lifecycle. Because the server is
bound for direct access, it remains reachable through LAN/Wi-Fi or a VPN when
those routes exist.

The existing custom-mode configuration and behavior should remain unchanged
except for being selected explicitly through `T3_MODE=custom` and
`T3_CUSTOM_ACCESS=full`.

### Optional activity publishing in custom mode

`T3_PUBLISH_ACTIVITY` remains independent of custom transport:

- `0` leaves T3 Connect publishing disabled and does not require a T3 account
  link.
- `1` uses the existing publish-only T3 Connect link and startup verification
  so push notifications and Live Activities work while access is provided
  directly or through the custom Cloudflare tunnel.

Publishing does not change how the server is reached. In connect mode this
setting is ignored because the full T3 Connect link owns that behavior.

## Script ownership

Add standalone `t3-start.sh` and `t3-stop.sh` scripts. They should own the T3
lifecycle and be usable without CodeLaunch.

- `start.sh` loads and validates the top-level feature flags, starts the
  optional Claudex path, and calls `t3-start.sh` when T3 is enabled.
- `stop.sh` calls `t3-stop.sh` and tears down any CodeLaunch-owned Claudex
  services. Shutdown should use recorded ownership/runtime state rather than
  assuming the current `.env` still matches the mode that was started.
- `t3-start.sh` selects connect, custom/direct, or custom/full and performs an
  idempotent start.
- `t3-stop.sh` performs an idempotent stop and leaves T3 account authentication
  in place. Stopping must not unlink T3 Connect.
- `t3-start.sh` replaces `t3-serve.sh`. Remove `t3-serve.sh` after all callers
  have migrated.

The scripts must retain process ownership information sufficient to avoid
stopping unrelated T3 Desktop or user-started processes.

## Detached-process requirements

The Connect startup path must return control to an SSH shell and survive that
SSH session closing. Success means:

- stdin, stdout, and stderr are detached from the SSH terminal;
- start is idempotent and does not create duplicate servers;
- immediate startup failures are reported;
- logs have a stable private location;
- stop targets only the process recorded or otherwise verified as owned;
- stale PID/ownership state is detected and repaired safely.

Prefer the T3 CLI's own background lifecycle if it provides one. Otherwise,
the wrapper must fully detach and verify the actual long-lived server process,
not merely the temporary `npx` parent.

## Implementation checklist

- [x] Add and document the new environment variables and defaults.
- [x] Gate Claudex, Docker, CLIProxyAPI, and their prerequisites behind
  `CLAUDEX_ENABLED`.
- [x] Add standalone, idempotent `t3-start.sh` and `t3-stop.sh`.
- [x] Implement T3 Connect status and link reconciliation.
- [x] Implement custom/direct without starting Cloudflare.
- [x] Preserve the current custom/full path.
- [x] Preserve optional publish-only activity in both custom access modes.
- [x] Make `start.sh` and `stop.sh` delegate the T3 lifecycle.
- [x] Remove `t3-serve.sh` after its callers are migrated.
- [x] Update README, setup, quick-setup, and example environment documentation.
- [ ] Manually verify detached startup and shutdown from an SSH session.
