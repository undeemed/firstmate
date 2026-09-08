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


# A watcher cycle that keeps reporting the SAME actionable line must queue ONE
# follow-up, not one per cycle: omp holds queued follow-ups until the run reads
# them, so an un-coalesced repeat pile grew to 19-24 identical notices in one
# pane. Consuming the queue (agent_start) must let the same line through again,
# because a repeat AFTER a read is genuinely new information.
test_omp_watch_coalesces_unread_duplicate_wakes() {
  local repo home out status
  repo="$TMP_ROOT/coalesce-root"
  home="$TMP_ROOT/coalesce-home"
  mkdir -p "$repo/bin" "$home/state" "$home/config"
  install_omp_watch_fixture "$repo"
  cat >"$repo/bin/fm-watch-arm.sh" <<'SH'
#!/usr/bin/env bash
# Every cycle reports the identical actionable line, which is exactly the
# repeating-wake shape this test pins.
echo "stale: default:w9S:p3"
exit 0
SH
  chmod +x "$repo/bin/fm-watch-arm.sh"
  out=$(
    PLUGIN="$repo/.omp/extensions/fm-primary-omp-watch.ts" FM_HOME="$home" FM_ROOT_OVERRIDE="$repo" \
    FM_WATCH_REARM_RETRY_BASE_MS=25 FM_WATCH_REARM_RETRY_MAX_MS=25 FM_WATCH_REARM_RETRY_LIMIT=50 node --input-type=module 2>&1 <<'EOF'
import { writeFileSync } from "node:fs";
import { pathToFileURL } from "node:url";

const handlers = {};
let armHandler = null;
const delivered = [];
const pi = {
  on(name, fn) {
    handlers[name] = fn;
  },
  registerCommand(name, options) {
    if (name === "fm-watch-arm-omp") armHandler = options.handler;
  },
  registerTool() {},
  sendUserMessage: async (content) => {
    delivered.push(content);
  },
};
writeFileSync(`${process.env.FM_HOME}/state/.lock`, `${process.pid}\n`);
const mod = await import(pathToFileURL(process.env.PLUGIN).href);
mod.default(pi);
await armHandler("", { ui: { notify() {} } });

const settle = async (ms) => {
  await new Promise((resolve) => setTimeout(resolve, ms));
};

// Wait for the first follow-up, then let several more arm cycles run: each one
// closes on the same actionable line, so an un-coalesced build queues one each.
for (let i = 0; i < 900 && delivered.length === 0; i += 1) await settle(20);
await settle(1200);
const beforeRead = delivered.length;
if (beforeRead !== 1) {
  console.error(`expected exactly 1 queued follow-up while unread, got ${beforeRead}`);
  process.exit(1);
}

// The run consumed its queue: the same line is now new information again.
if (typeof handlers.agent_start !== "function") {
  console.error("omp watch did not register an agent_start handler");
  process.exit(1);
}
handlers.agent_start();
for (let i = 0; i < 900 && delivered.length === beforeRead; i += 1) await settle(20);
if (delivered.length <= beforeRead) {
  console.error(`a repeat after the queue was read must deliver again; still ${delivered.length}`);
  process.exit(1);
}
if (!delivered[0].includes("stale: default:w9S:p3")) {
  console.error(`unexpected follow-up body: ${delivered[0]}`);
  process.exit(1);
}
// The extension keeps re-arming by design, so nothing ends this process for us.
process.exit(0);
EOF
  )
  status=$?
  [ "$status" = 0 ] || printf 'DIAG: %s\n' "$out"
  expect_code 0 "$status" "omp watch must queue one follow-up per unread duplicate wake, and deliver again after a read"
  [ -z "$out" ] || fail "omp coalescing test printed output: $out"
  pass "omp watch coalesces identical unread wakes and re-delivers after the queue is read"
}

test_omp_watch_coalesces_distinct_pending_wakes() {
  local repo home out status
  repo="$TMP_ROOT/coalesce-distinct-root"
  home="$TMP_ROOT/coalesce-distinct-home"
  mkdir -p "$repo/bin" "$home/state" "$home/config"
  install_omp_watch_fixture "$repo"
  cat >"$repo/bin/fm-watch-arm.sh" <<'SH'
#!/usr/bin/env bash
set -u
count_file="${FM_HOME}/state/arm-count"
count=0
if [ -f "$count_file" ]; then
  count=$(cat "$count_file")
fi
count=$((count + 1))
printf '%s\n' "$count" >"$count_file"
if [ "$count" -le 2 ]; then
  printf 'signal: distinct-wake-%s\n' "$count"
  if [ "$count" -eq 1 ]; then
    exit 0
  fi
fi
printf 'watcher: started\n'
sleep 5
SH
  chmod +x "$repo/bin/fm-watch-arm.sh"
  out=$(
    PLUGIN="$repo/.omp/extensions/fm-primary-omp-watch.ts" FM_HOME="$home" FM_ROOT_OVERRIDE="$repo" \
      FM_WATCH_REARM_RETRY_BASE_MS=5 FM_WATCH_REARM_RETRY_MAX_MS=10 FM_WATCH_REARM_RETRY_LIMIT=2 \
      node --input-type=module 2>&1 <<'EOF'
import { writeFileSync } from "node:fs";
import { pathToFileURL } from "node:url";

const prompts = [];
let handler = null;
const pi = {
  on() {},
  registerCommand(name, options) {
    if (name === "fm-watch-arm-omp") handler = options.handler;
  },
  registerTool() {},
  sendUserMessage: async (message) => {
    prompts.push(message);
  },
};
writeFileSync(`${process.env.FM_HOME}/state/.lock`, `${process.pid}\n`);
const mod = await import(pathToFileURL(process.env.PLUGIN).href);
mod.default(pi);
await handler("", { ui: { notify() {} } });
for (let i = 0; i < 250 && prompts.length < 2; i += 1) {
  await new Promise((resolve) => setTimeout(resolve, 20));
}
if (prompts.length !== 1) {
  console.error(`expected one coalesced wake, got ${prompts.length}`);
  process.exitCode = 1;
}
if (prompts[0] && !prompts[0].includes("distinct-wake-1")) {
  console.error(`first wake was not preserved: ${prompts[0]}`);
  process.exitCode = 1;
}
EOF
  )
  status=$?
  expect_code 0 "$status" "omp watcher must coalesce distinct pending wakes"
  [ -z "$out" ] || fail "omp distinct-wake coalescing test printed output: $out"
  pass "omp watcher coalesces distinct pending wakes until agent consumption"
}

# A claimed follow-up that omp never delivers (it clears queued messages when a
# turn aborts) must not silence the session: measured on 2026-09-08, one mate sat
# 26h with four unread durable rows and an idle pane because the claim was taken
# once and never expired after the session's first consumption boundary. The TTL
# is the unconditional backstop.
test_omp_watch_expires_a_claim_whose_follow_up_was_lost() {
  local repo home out status
  repo="$TMP_ROOT/ttl-root"
  home="$TMP_ROOT/ttl-home"
  mkdir -p "$repo/bin" "$home/state" "$home/config"
  install_omp_watch_fixture "$repo"
  cat >"$repo/bin/fm-watch-arm.sh" <<'SH'
#!/usr/bin/env bash
echo "stale: default:w9S:p3"
exit 0
SH
  chmod +x "$repo/bin/fm-watch-arm.sh"
  out=$(
    PLUGIN="$repo/.omp/extensions/fm-primary-omp-watch.ts" FM_HOME="$home" FM_ROOT_OVERRIDE="$repo" \
      FM_WATCH_REARM_RETRY_BASE_MS=5 FM_WATCH_REARM_RETRY_MAX_MS=10 FM_WATCH_REARM_RETRY_LIMIT=2 \
      FM_WATCH_WAKE_COALESCE_TTL_MS=400 node --input-type=module 2>&1 <<'EOF'
import { writeFileSync } from "node:fs";
import { pathToFileURL } from "node:url";

const handlers = {};
let armHandler = null;
const delivered = [];
const pi = {
  on(name, fn) {
    handlers[name] = fn;
  },
  registerCommand(name, options) {
    if (name === "fm-watch-arm-omp") armHandler = options.handler;
  },
  registerTool() {},
  sendUserMessage: async (content) => {
    delivered.push(content);
  },
};
writeFileSync(`${process.env.FM_HOME}/state/.lock`, `${process.pid}\n`);
const mod = await import(pathToFileURL(process.env.PLUGIN).href);
mod.default(pi);
await armHandler("", { ui: { notify() {} } });

const settle = (ms) => new Promise((resolve) => setTimeout(resolve, ms));
const waitForCount = async (target) => {
  for (let i = 0; i < 900 && delivered.length < target; i += 1) await settle(20);
  return delivered.length;
};

if ((await waitForCount(1)) < 1) {
  console.error("no first wake was delivered");
  process.exit(1);
}
// One real consumption boundary, exactly as a healthy session reports it.
handlers.agent_start();
if ((await waitForCount(2)) < 2) {
  console.error("a repeat after the queue was read must deliver again");
  process.exit(1);
}
const claimed = delivered.length;
// From here the follow-up is LOST: no agent_start ever consumes it. Past the
// TTL the next cycle must still reach the session.
for (let i = 0; i < 900 && delivered.length === claimed; i += 1) await settle(20);
if (delivered.length <= claimed) {
  console.error(`a claim whose follow-up was lost never expired; still ${delivered.length}`);
  process.exit(1);
}
process.exit(0);
EOF
  )
  status=$?
  [ "$status" = 0 ] || printf 'DIAG: %s\n' "$out"
  expect_code 0 "$status" "omp watch must expire a claimed wake whose follow-up was never consumed"
  [ -z "$out" ] || fail "omp ttl test printed output: $out"
  pass "omp watch expires a claimed wake whose follow-up was lost, after the coalesce TTL"
}

# A run that ends without consuming the queued wake settles the session at idle,
# so the claim is stale immediately and the next wake must not wait out the TTL.
test_omp_watch_releases_claim_when_a_run_ends_unconsumed() {
  local repo home out status
  repo="$TMP_ROOT/agent-end-root"
  home="$TMP_ROOT/agent-end-home"
  mkdir -p "$repo/bin" "$home/state" "$home/config"
  install_omp_watch_fixture "$repo"
  cat >"$repo/bin/fm-watch-arm.sh" <<'SH'
#!/usr/bin/env bash
echo "stale: default:w9S:p3"
exit 0
SH
  chmod +x "$repo/bin/fm-watch-arm.sh"
  out=$(
    PLUGIN="$repo/.omp/extensions/fm-primary-omp-watch.ts" FM_HOME="$home" FM_ROOT_OVERRIDE="$repo" \
      FM_WATCH_REARM_RETRY_BASE_MS=5 FM_WATCH_REARM_RETRY_MAX_MS=10 FM_WATCH_REARM_RETRY_LIMIT=2 \
      FM_WATCH_WAKE_COALESCE_TTL_MS=600000 node --input-type=module 2>&1 <<'EOF'
import { writeFileSync } from "node:fs";
import { pathToFileURL } from "node:url";

const handlers = {};
let armHandler = null;
const delivered = [];
const pi = {
  on(name, fn) {
    handlers[name] = fn;
  },
  registerCommand(name, options) {
    if (name === "fm-watch-arm-omp") armHandler = options.handler;
  },
  registerTool() {},
  sendUserMessage: async (content) => {
    delivered.push(content);
  },
};
writeFileSync(`${process.env.FM_HOME}/state/.lock`, `${process.pid}\n`);
const mod = await import(pathToFileURL(process.env.PLUGIN).href);
mod.default(pi);
await armHandler("", { ui: { notify() {} } });

const settle = (ms) => new Promise((resolve) => setTimeout(resolve, ms));
for (let i = 0; i < 900 && delivered.length === 0; i += 1) await settle(20);
if (delivered.length === 0) {
  console.error("no first wake was delivered");
  process.exit(1);
}
if (typeof handlers.agent_end !== "function") {
  console.error("omp watch did not register an agent_end handler");
  process.exit(1);
}
const claimed = delivered.length;
// A scheduled continuation is not an idle boundary: the queued wake may still
// be read, so the claim stands.
handlers.agent_end({ willContinue: true });
await settle(300);
if (delivered.length !== claimed) {
  console.error(`a continuing run must not release the claim; got ${delivered.length}`);
  process.exit(1);
}
// A settled run did not read the queue, so the claim is released well inside
// the ten-minute TTL this test configures.
handlers.agent_end({});
for (let i = 0; i < 900 && delivered.length === claimed; i += 1) await settle(20);
if (delivered.length <= claimed) {
  console.error(`a settled run left the claim held; still ${delivered.length}`);
  process.exit(1);
}
process.exit(0);
EOF
  )
  status=$?
  [ "$status" = 0 ] || printf 'DIAG: %s\n' "$out"
  expect_code 0 "$status" "omp watch must release an unconsumed claim when a run settles"
  [ -z "$out" ] || fail "omp agent_end test printed output: $out"
  pass "omp watch releases an unconsumed wake claim when a run settles, and keeps it while one continues"
}

# omp's idle-path auto-continue for a queued follow-up is gated on the transcript
# tail and on no prior interrupt, so a follow-up queued into an idle session can
# sit unread (measured: a wake stranded behind a trailing advisor card). Omitting
# deliverAs runs the wake now when idle; only a streaming wake keeps followUp.
test_omp_watch_delivers_an_idle_wake_as_a_turn() {
  local repo home out status
  repo="$TMP_ROOT/delivery-root"
  home="$TMP_ROOT/delivery-home"
  mkdir -p "$repo/bin" "$home/state" "$home/config"
  install_omp_watch_fixture "$repo"
  cat >"$repo/bin/fm-watch-arm.sh" <<'SH'
#!/usr/bin/env bash
echo "stale: default:w9S:p3"
exit 0
SH
  chmod +x "$repo/bin/fm-watch-arm.sh"
  out=$(
    PLUGIN="$repo/.omp/extensions/fm-primary-omp-watch.ts" FM_HOME="$home" FM_ROOT_OVERRIDE="$repo" \
      FM_WATCH_REARM_RETRY_BASE_MS=5 FM_WATCH_REARM_RETRY_MAX_MS=10 FM_WATCH_REARM_RETRY_LIMIT=2 \
      FM_WATCH_WAKE_COALESCE_TTL_MS=600000 node --input-type=module 2>&1 <<'EOF'
import { writeFileSync } from "node:fs";
import { pathToFileURL } from "node:url";

const handlers = {};
let armHandler = null;
const modes = [];
const pi = {
  on(name, fn) {
    handlers[name] = fn;
  },
  registerCommand(name, options) {
    if (name === "fm-watch-arm-omp") armHandler = options.handler;
  },
  registerTool() {},
  sendUserMessage: async (_content, options) => {
    modes.push(options === undefined ? "turn" : options.deliverAs);
  },
};
writeFileSync(`${process.env.FM_HOME}/state/.lock`, `${process.pid}\n`);
const mod = await import(pathToFileURL(process.env.PLUGIN).href);
mod.default(pi);
await armHandler("", { ui: { notify() {} } });

const settle = (ms) => new Promise((resolve) => setTimeout(resolve, ms));
for (let i = 0; i < 900 && modes.length === 0; i += 1) await settle(20);
if (modes[0] !== "turn") {
  console.error(`an idle wake must start a turn, got ${String(modes[0])}`);
  process.exit(1);
}
// The session is now streaming, so the wake queues behind the live run instead
// of racing it.
handlers.agent_start();
for (let i = 0; i < 900 && modes.length < 2; i += 1) await settle(20);
if (modes[1] !== "followUp") {
  console.error(`a streaming wake must queue as a follow-up, got ${String(modes[1])}`);
  process.exit(1);
}
process.exit(0);
EOF
  )
  status=$?
  [ "$status" = 0 ] || printf 'DIAG: %s\n' "$out"
  expect_code 0 "$status" "omp watch must deliver an idle wake as a turn and a streaming wake as a follow-up"
  [ -z "$out" ] || fail "omp delivery-mode test printed output: $out"
  pass "omp watch runs an idle wake as a turn and queues a streaming wake as a follow-up"
}

test_omp_watch_registers_named_tool_and_command
test_omp_watch_reports_external_healthy_watcher
test_omp_watch_retires_generation_on_shutdown
test_omp_watch_coalesces_unread_duplicate_wakes
test_omp_watch_coalesces_distinct_pending_wakes
test_omp_watch_expires_a_claim_whose_follow_up_was_lost
test_omp_watch_releases_claim_when_a_run_ends_unconsumed
test_omp_watch_delivers_an_idle_wake_as_a_turn
