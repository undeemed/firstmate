#!/usr/bin/env bash
# Behavior tests for the omp primary watcher extension
# (.omp/extensions/fm-primary-omp-watch.ts): tool/command identity, arm start,
# external-healthy owned-wake failure, and session-generation retirement.
#
# Mirrors tests/fm-pi-watch-extension.test.sh conventions. The omp watcher
# registers a plain JSON-schema tool (no typebox, no pi-tui), so its fixture
# needs no package stubs - only the tracked extension, the shared
# operational-input adapter at extensions/lib/, and its shell owner. The
# extension imports ../../extensions/lib/fm-operational-input.ts, so the shared
# lib must sit at <repo>/extensions/lib/ for the import to resolve.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

EXT="$ROOT/.omp/extensions/fm-primary-omp-watch.ts"
TMP_ROOT=$(fm_test_tmproot fm-omp-watch-extension)

command -v node >/dev/null 2>&1 || {
  echo "skip: node not found for omp watch extension"
  exit 0
}

install_omp_watch_fixture() {
  local repo=$1
  mkdir -p "$repo/.omp/extensions" "$repo/extensions/lib" "$repo/bin"
  cp "$EXT" "$repo/.omp/extensions/fm-primary-omp-watch.ts"
  cp "$ROOT/extensions/lib/fm-operational-input.ts" "$repo/extensions/lib/fm-operational-input.ts"
  cp "$ROOT/bin/fm-operational-input.sh" "$repo/bin/fm-operational-input.sh"
  chmod +x "$repo/bin/fm-operational-input.sh"
}

test_omp_watch_registers_named_tool_and_command() {
  local repo home out status
  repo="$TMP_ROOT/names-root"
  home="$TMP_ROOT/names-home"
  mkdir -p "$repo/bin" "$home/state" "$home/config"
  install_omp_watch_fixture "$repo"
  cat >"$repo/bin/fm-watch-arm.sh" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  chmod +x "$repo/bin/fm-watch-arm.sh"
  out=$(
    PLUGIN="$repo/.omp/extensions/fm-primary-omp-watch.ts" FM_HOME="$home" FM_ROOT_OVERRIDE="$repo" node --input-type=module 2>&1 <<'EOF'
import { writeFileSync } from "node:fs";
import { pathToFileURL } from "node:url";

let commandName = null;
let toolName = null;
let toolParameters = null;
let armHandler = null;
let notification = "";
const pi = {
  on() {},
  registerCommand(name, options) {
    commandName = name;
    armHandler = options.handler;
  },
  registerTool(spec) {
    toolName = spec.name;
    toolParameters = spec.parameters;
  },
  sendUserMessage: async () => {},
};
writeFileSync(`${process.env.FM_HOME}/state/.lock`, `${process.pid}\n`);
const mod = await import(pathToFileURL(process.env.PLUGIN).href);
mod.default(pi);
if (commandName !== "fm-watch-arm-omp") {
  console.error(`command name: ${commandName}`);
  process.exit(1);
}
if (toolName !== "fm_watch_arm_omp") {
  console.error(`tool name: ${toolName}`);
  process.exit(1);
}
if (!toolParameters || toolParameters.type !== "object") {
  console.error(`tool parameters: ${JSON.stringify(toolParameters)}`);
  process.exit(1);
}
const result = await armHandler("", {
  ui: {
    notify(message) {
      notification = message;
    },
  },
});
if (result !== undefined) {
  console.error(`omp command returned a value: ${String(result)}`);
  process.exit(1);
}
if (!notification.includes("started omp extension arm child")) {
  console.error(notification);
  process.exit(1);
}
EOF
  )
  status=$?
  expect_code 0 "$status" "omp watch must register omp-named tool+command and start an arm child"
  [ -z "$out" ] || fail "omp names test printed output: $out"
  pass "omp watch registers fm_watch_arm_omp tool + fm-watch-arm-omp command and starts an arm child"
}

test_omp_watch_reports_external_healthy_watcher() {
  local repo home out status
  repo="$TMP_ROOT/healthy-root"
  home="$TMP_ROOT/healthy-home"
  mkdir -p "$repo/bin" "$home/state" "$home/config"
  install_omp_watch_fixture "$repo"
  cat >"$repo/bin/fm-watch-arm.sh" <<'SH'
#!/usr/bin/env bash
printf 'watcher: healthy pid=1 (beacon 0s)\n'
SH
  chmod +x "$repo/bin/fm-watch-arm.sh"
  out=$(
    PLUGIN="$repo/.omp/extensions/fm-primary-omp-watch.ts" FM_HOME="$home" FM_ROOT_OVERRIDE="$repo" \
      FM_WATCH_REARM_RETRY_BASE_MS=5 FM_WATCH_REARM_RETRY_MAX_MS=10 FM_WATCH_REARM_RETRY_LIMIT=2 \
      node --input-type=module 2>&1 <<'EOF'
import { writeFileSync } from "node:fs";
import { pathToFileURL } from "node:url";

let handler = null;
let notification = "";
let prompt = "";
const pi = {
  on() {},
  registerCommand(name, options) {
    if (name === "fm-watch-arm-omp") handler = options.handler;
  },
  registerTool() {},
  sendUserMessage: async (message) => {
    prompt = message;
  },
};
writeFileSync(`${process.env.FM_HOME}/state/.lock`, `${process.pid}\n`);
const mod = await import(pathToFileURL(process.env.PLUGIN).href);
mod.default(pi);
if (!handler) {
  console.error("omp watch command was not registered");
  process.exit(1);
}
const result = await handler("", {
  ui: {
    notify(message) {
      notification = message;
    },
  },
});
if (result !== undefined) {
  console.error(`omp command returned a value: ${String(result)}`);
  process.exit(1);
}
if (!notification.includes("started omp extension arm child")) {
  console.error(notification);
  process.exit(1);
}
for (let i = 0; i < 250 && !prompt; i += 1) {
  await new Promise((resolve) => setTimeout(resolve, 20));
}
if (!prompt.startsWith("\u2063FIRSTMATE_OP: v1 watcher: ")) {
  console.error(`untyped operational follow-up: ${prompt}`);
  process.exit(1);
}
if (!prompt.includes("FIRSTMATE WATCHER WAKE")) {
  console.error(`missing follow-up prompt: ${prompt}`);
  process.exit(1);
}
if (!prompt.includes("external healthy watcher")) {
  console.error(prompt);
  process.exit(1);
}
if (!prompt.includes("watcher: healthy pid=1")) {
  console.error(prompt);
  process.exit(1);
}
EOF
  )
  status=$?
  expect_code 0 "$status" "omp extension must surface an external healthy watcher as an owned-wake failure"
  [ -z "$out" ] || fail "omp external-healthy test printed output: $out"
  pass "omp watch reports an external healthy watcher as an owned-wake failure"
}

test_omp_watch_retires_generation_on_shutdown() {
  local repo home out status
  repo="$TMP_ROOT/generation-root"
  home="$TMP_ROOT/generation-home"
  mkdir -p "$repo/bin" "$home/state" "$home/config"
  install_omp_watch_fixture "$repo"
  cat >"$repo/bin/fm-watch-arm.sh" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  chmod +x "$repo/bin/fm-watch-arm.sh"
  out=$(
    PLUGIN="$repo/.omp/extensions/fm-primary-omp-watch.ts" FM_HOME="$home" FM_ROOT_OVERRIDE="$repo" node --input-type=module 2>&1 <<'EOF'
import { writeFileSync } from "node:fs";
import { pathToFileURL } from "node:url";

const handlers = {};
let armHandler = null;
let notification = "";
const pi = {
  on(name, fn) {
    handlers[name] = fn;
  },
  registerCommand(name, options) {
    if (name === "fm-watch-arm-omp") armHandler = options.handler;
  },
  registerTool() {},
  sendUserMessage: async () => {},
};
writeFileSync(`${process.env.FM_HOME}/state/.lock`, `${process.pid}\n`);
const mod = await import(pathToFileURL(process.env.PLUGIN).href);
mod.default(pi);
if (typeof handlers.session_shutdown !== "function") {
  console.error("omp watch did not register a session_shutdown handler");
  process.exit(1);
}
// Terminal quit retires the active generation; a later manual arm must refuse
// rather than spawn an orphan child no live generation owns.
handlers.session_shutdown();
await armHandler("", {
  ui: {
    notify(message) {
      notification = message;
    },
  },
});
if (!notification.includes("omp session is shutting down")) {
  console.error(`shutdown arm notification: ${notification}`);
  process.exit(1);
}
EOF
  )
  status=$?
  expect_code 0 "$status" "omp watch must refuse to arm after its generation is retired at shutdown"
  [ -z "$out" ] || fail "omp generation test printed output: $out"
  pass "omp watch retires its session generation on shutdown and refuses a late arm"
}

test_omp_watch_registers_named_tool_and_command
test_omp_watch_reports_external_healthy_watcher
test_omp_watch_retires_generation_on_shutdown
