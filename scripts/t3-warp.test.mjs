import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { afterEach, test } from 'node:test';
import { fileURLToPath } from 'node:url';

const codeLaunch = fileURLToPath(new URL('..', import.meta.url));
const sourceRepo = process.env.T3_WARP_TEST_REPO || path.join(codeLaunch, '../t3-code-warp');
const directories = [];

afterEach(() => {
  for (const directory of directories.splice(0)) fs.rmSync(directory, { recursive: true, force: true });
});

function fixture() {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'codelaunch-warp-'));
  directories.push(root);
  const home = path.join(root, 'home');
  const launch = path.join(root, 'CodeLaunch');
  const repo = path.join(root, 'source checkout');
  for (const dir of [home, path.join(launch, 'scripts'), path.join(root, 'bin'), path.join(repo, 't3code/scripts/lib')]) {
    fs.mkdirSync(dir, { recursive: true });
  }
  for (const file of ['scripts/env.sh', 't3-publish.sh']) {
    fs.copyFileSync(path.join(codeLaunch, file), path.join(launch, file));
  }
  for (const file of ['scripts/warp-preflight.ts', 'scripts/lib/public-config.ts']) {
    fs.copyFileSync(path.join(sourceRepo, 't3code', file), path.join(repo, 't3code', file));
  }
  fs.writeFileSync(path.join(repo, 't3code/package.json'), '{"type":"module","engines":{"node":"26.13.1"}}');
  const calls = path.join(root, 'calls');
  fs.writeFileSync(path.join(repo, 't3code/scripts/warp-cli.ts'), `
import fs from 'node:fs';
fs.appendFileSync(process.env.FIXTURE_CALLS, JSON.stringify(process.argv.slice(2)) + '\\n');
if (process.argv.slice(2).join(' ') !== 'connect status --json') throw new Error('unexpected CLI mutation');
console.log(process.env.FIXTURE_STATUS);
`);
  fs.writeFileSync(path.join(root, 'bin/fnm'), `#!/bin/sh\n[ "$1" = exec ] && [ "$2" = --using=26.13.1 ] || exit 1\nprintf '%s\\n' '${process.execPath}'\n`, { mode: 0o700 });
  fs.writeFileSync(path.join(launch, '.env'), `T3_MODE=custom\nT3_PORT=49999\nT3_PUBLISH_ACTIVITY=1\nT3_WARP_REPO="${repo}"\n`, { mode: 0o600 });
  return {
    root, home, launch, repo, calls,
    env: { HOME: home, PATH: `${path.join(root, 'bin')}:${process.env.PATH}`, FIXTURE_CALLS: calls },
  };
}

function assets(f) {
  for (const file of [
    't3code/apps/web/dist/index.html',
    'warp/target/t3-bundle/current/assets/client/wasm/warp.js',
    'warp/target/t3-bundle/current/assets/client/wasm/warp_bg.wasm',
    'warp/target/t3-bundle/current/assets/client/wasm/warp_bg.wasm.br',
  ]) {
    const dest = path.join(f.repo, file);
    fs.mkdirSync(path.dirname(dest), { recursive: true });
    fs.writeFileSync(dest, 'fixture asset');
  }
}

function dependencies(f) {
  fs.mkdirSync(path.join(f.repo, 't3code/apps/server'), { recursive: true });
  fs.symlinkSync(path.join(sourceRepo, 't3code/apps/server/node_modules'), path.join(f.repo, 't3code/apps/server/node_modules'));
  const modules = path.join(f.repo, 'panelwarp/node_modules');
  fs.mkdirSync(modules, { recursive: true });
  for (const name of ['ws', 'smol-toml', 'zod']) {
    fs.symlinkSync(path.join(sourceRepo, 'panelwarp/node_modules', name), path.join(modules, name));
  }
  fs.cpSync(fs.realpathSync(path.join(sourceRepo, 'panelwarp/node_modules/node-pty')), path.join(modules, 'node-pty'), { recursive: true });
  const helper = path.join(modules, 'node-pty/prebuilds', `${process.platform}-${process.arch}`, 'spawn-helper');
  fs.chmodSync(helper, 0o700);
  return helper;
}

function shell(f, command, extra = {}) {
  return spawnSync('/bin/bash', ['--noprofile', '--norc', '-c', command], {
    cwd: f.launch, env: { ...f.env, ...extra }, encoding: 'utf8', timeout: 15_000,
  });
}

test('source preflight catches missing bundles, dependencies and the npm helper permission defect', () => {
  const f = fixture();
  const init = 'source scripts/env.sh; codelaunch_load_env T3_WARP_REPO; codelaunch_t3_cli_init t3@fixture';
  let result = shell(f, init);
  assert.equal(result.status, 1);
  assert.match(result.stderr, /VITE_HTTP_URL= VITE_WS_URL= vp run --filter @t3tools\/web build/);
  assets(f);
  fs.truncateSync(path.join(f.repo, 'warp/target/t3-bundle/current/assets/client/wasm/warp_bg.wasm.br'));
  result = shell(f, init);
  assert.equal(result.status, 1);
  assert.match(result.stderr, /warp_bg\.wasm\.br/);
  assets(f);
  result = shell(f, init);
  assert.equal(result.status, 1);
  assert.match(result.stderr, /Missing T3 dependency/);
  const helper = dependencies(f);
  fs.chmodSync(helper, 0o600);
  result = shell(f, init);
  assert.equal(result.status, 1);
  assert.match(result.stderr, /chmod u\+x/);
  assert.ok(result.stderr.includes(helper));
  assert.equal(fs.statSync(helper).mode & 0o100, 0);
  fs.chmodSync(helper, 0o700);
  result = shell(f, `${init}; printf '%s\n' "\${CODELAUNCH_T3_CLI[@]}"`);
  assert.equal(result.status, 0, result.stderr);
  assert.equal(result.stdout, `${process.execPath}\n${f.repo}/t3code/scripts/warp-cli.ts\n`);
  assert.equal(fs.existsSync(path.join(f.home, '.t3')), false);
  const spawn = spawnSync(process.execPath, ['-e', `
const { createRequire } = require('node:module');
const load = createRequire(process.argv[1] + '/package.json');
const terminal = load('node-pty').spawn(process.execPath, ['-e', 'process.exit(0)'], {
  cwd: process.env.HOME, env: process.env,
});
const timeout = setTimeout(() => { terminal.kill(); process.exitCode = 1; }, 5000);
terminal.onExit(({ exitCode }) => { clearTimeout(timeout); process.exitCode = exitCode; });
`, path.join(f.repo, 'panelwarp')], { env: f.env, encoding: 'utf8', timeout: 10_000 });
  assert.equal(spawn.status, 0, spawn.stderr);
});

test('empty source opt-in preserves the packaged CLI', () => {
  const f = fixture();
  const result = shell(f, 'source scripts/env.sh; codelaunch_t3_cli_init t3@fixture; printf "%s\\n" "${CODELAUNCH_T3_CLI[@]}"');
  assert.equal(result.status, 0, result.stderr);
  assert.equal(result.stdout, 'npx\n--yes\nt3@fixture\n');
});

test('publishing without public config gives guidance while local launch stays usable', () => {
  const f = fixture();
  assets(f);
  dependencies(f);
  const result = shell(f, './t3-publish.sh --check-only');
  assert.equal(result.status, 0, result.stderr);
  assert.match(result.stderr, /T3CODE_CLERK_PUBLISHABLE_KEY/);
  assert.match(result.stderr, /Local serving and pairing work without it/);
  assert.match(result.stdout, /WARNING: publishing unavailable/);
  assert.equal(fs.existsSync(f.calls), false);
  assert.equal(fs.existsSync(path.join(f.home, '.t3')), false);
});

test('publish checks require desired publish-only mode, authorization and a non-revoked provisioned link', () => {
  const f = fixture();
  assets(f);
  dependencies(f);
  fs.writeFileSync(path.join(f.repo, 't3code/.env.local'), 'VITE_T3CODE_RELAY_URL=https://relay.example.test\nVITE_CLERK_PUBLISHABLE_KEY=pk_fixture\nVITE_CLERK_CLI_OAUTH_CLIENT_ID=fixture-client\n');
  const ready = { desired: true, authenticated: true, linked: true, revoked: false, linkMode: 'publish_only', publishAgentActivity: true };
  for (const [patch, message] of [
    [{}, /publish agent activity ok/],
    [{ desired: false }, /no desired environment link/],
    [{ revoked: true }, /environment link revoked/],
    [{ linkMode: 'managed' }, /managed link mode/],
    [{ linked: false }, /environment link pending/],
    [{ authenticated: false }, /not signed in/],
    [{ publishAgentActivity: false }, /publishing flag is off/],
  ]) {
    const result = shell(f, './t3-publish.sh --check-only', { FIXTURE_STATUS: JSON.stringify({ ...ready, ...patch }) });
    assert.equal(result.status, 0, result.stderr);
    assert.match(result.stdout, message);
    if (Object.keys(patch).length) assert.doesNotMatch(result.stdout, /publish agent activity ok/);
  }
  const managed = shell(f, './t3-publish.sh --verify-only', {
    FIXTURE_STATUS: JSON.stringify({ ...ready, linkMode: 'managed' }),
  });
  assert.equal(managed.status, 0, managed.stderr);
  assert.match(managed.stdout, /managed link mode/);
  assert.equal(fs.existsSync(path.join(f.home, '.codelaunch')), false);
  const incomplete = { ...ready };
  delete incomplete.linkMode;
  const invalid = shell(f, './t3-publish.sh --check-only', { FIXTURE_STATUS: JSON.stringify(incomplete) });
  assert.equal(invalid.status, 1, invalid.stderr);
  assert.match(invalid.stdout, /invalid or incomplete JSON/);
  const calls = fs.readFileSync(f.calls, 'utf8').trim().split('\n').map(JSON.parse);
  assert.equal(calls.length, 9);
  assert.ok(calls.every((args) => JSON.stringify(args) === '["connect","status","--json"]'));
});

test('both server recognizers keep packaged and old source servers and exclude desktop and daemon', () => {
  const f = fixture();
  const result = shell(f, `
source scripts/env.sh
ps() {
  case "$*" in
    *'101'*) echo '/node /checkout/t3code/scripts/warp-cli.ts serve --host 0.0.0.0' ;;
    *'102'*) echo '/node /checkout/t3code/apps/server/src/bin.ts serve' ;;
    *'103'*) echo '/package/t3 serve' ;;
    *'104'*) echo '/Applications/T3.app/Contents/MacOS/t3 serve' ;;
    *'105'*) echo '/node /checkout/panelwarp/daemon.js' ;;
  esac
}
pgrep() {
  case "$*" in
    '-P 100') printf '101\\n105\\n' ;;
    '-P '*) return 1 ;;
    '-f '*)
      case "$2" in *'/t3code/scripts/warp-cli\\.ts serve'*) printf '101\\n102\\n103\\n104\\n105\\n' ;; *) return 1 ;; esac ;;
  esac
}
codelaunch_t3_is_serve 101 || exit 1
codelaunch_t3_is_serve 102 || exit 1
codelaunch_t3_is_serve 103 || exit 1
if codelaunch_t3_is_serve 104 || codelaunch_t3_is_serve 105; then exit 1; fi
codelaunch_t3_unowned_pids 102
codelaunch_t3_descendant_pids 100
`);
  assert.equal(result.status, 0, result.stderr);
  assert.equal(result.stdout, '101\n103\n101\n');
});

test('ownership still requires matching PID, command and start identity', () => {
  const f = fixture();
  const result = shell(f, `
source scripts/env.sh
mkdir -p "$HOME/.codelaunch/run"
printf '101\\nstart-identity\\n/node /checkout/t3code/scripts/warp-cli.ts serve\\ncustom-full\\n' > "$HOME/.codelaunch/run/t3-serve.pid"
kill() { [ "$*" = '-0 101' ]; }
codelaunch_t3_command() { printf '%s\\n' "$FIXTURE_COMMAND"; }
codelaunch_t3_start_identity() { printf '%s\\n' "$FIXTURE_IDENTITY"; }
FIXTURE_COMMAND='/node /checkout/t3code/scripts/warp-cli.ts serve'
FIXTURE_IDENTITY=start-identity
codelaunch_t3_state_matches 101 || exit 1
if codelaunch_t3_state_matches 102; then exit 1; fi
FIXTURE_COMMAND='/node /other/t3code/scripts/warp-cli.ts serve'
if codelaunch_t3_state_matches 101; then exit 1; fi
FIXTURE_COMMAND='/node /checkout/t3code/scripts/warp-cli.ts serve'
FIXTURE_IDENTITY=recycled-identity
if codelaunch_t3_state_matches 101; then exit 1; fi
`);
  assert.equal(result.status, 0, result.stderr);
});
