#!/usr/bin/env bash
# Behavior tests for the omp primary turn-end guard
# (.omp/extensions/fm-primary-turnend-guard.ts).
#
# The pi guard fires on "agent_settled"; omp has no such event, so its guard
# fires on "agent_end" gated by omp's settle triple. This suite drives the
# registered agent_end handler with a mock omp and asserts the guard's
# fm-turnend-guard.sh only runs when all three signals agree the run is idle
# (willContinue false, isIdle() true, hasPendingMessages() false), that an idle
# settle with a blind turn sends the typed turn-end-guard follow-up, and that
# the follow-up latch suppresses exactly one re-entrant settle.
#
# The guard imports ../../extensions/lib/fm-operational-input.ts, so the shared
# lib must sit at <repo>/extensions/lib/ for the import to resolve.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

EXT="$ROOT/.omp/extensions/fm-primary-turnend-guard.ts"
TMP_ROOT=$(fm_test_tmproot fm-omp-turnend-guard)

command -v node >/dev/null 2>&1 || {
  echo "skip: node not found for omp turn-end guard"
  exit 0
}

test_omp_guard_settle_triple_gates_and_latches() {
  local repo home guard_log out status
  repo="$TMP_ROOT/guard-root"
  home="$TMP_ROOT/guard-home"
  guard_log="$TMP_ROOT/guard-runs.log"
  mkdir -p "$repo/.omp/extensions" "$repo/extensions/lib" "$repo/bin" "$repo/state"
  cp "$EXT" "$repo/.omp/extensions/fm-primary-turnend-guard.ts"
  cp "$ROOT/extensions/lib/fm-operational-input.ts" "$repo/extensions/lib/fm-operational-input.ts"
  cp "$ROOT/bin/fm-operational-input.sh" "$repo/bin/fm-operational-input.sh"
  chmod +x "$repo/bin/fm-operational-input.sh"
  # A blind turn: the guard exits 2, and each invocation records one mark so the
  # test can count how many settles actually reached the guard.
  cat >"$repo/bin/fm-turnend-guard.sh" <<'SH'
#!/usr/bin/env bash
printf 'x' >> "$FM_TURNEND_LOG"
printf 'guard-fired\n' >&2
exit 2
SH
  chmod +x "$repo/bin/fm-turnend-guard.sh"
  : >"$guard_log"
  out=$(
    PLUGIN="$repo/.omp/extensions/fm-primary-turnend-guard.ts" FM_HOME="$repo" FM_ROOT_OVERRIDE="$repo" \
      FM_TURNEND_LOG="$guard_log" node --input-type=module 2>&1 <<'EOF'
import { readFileSync, writeFileSync } from "node:fs";
import { pathToFileURL } from "node:url";

const guardLog = process.env.FM_TURNEND_LOG;
const runs = () => {
  try {
    return readFileSync(guardLog, "utf8").length;
  } catch {
    return 0;
  }
};

const handlers = {};
let prompt = "";
const pi = {
  on(name, fn) {
    handlers[name] = fn;
  },
  sendMessage() {},
  sendUserMessage: async (message) => {
    prompt = message;
  },
};
writeFileSync(`${process.env.FM_HOME}/state/.lock`, `${process.pid}\n`);
const mod = await import(pathToFileURL(process.env.PLUGIN).href);
mod.default(pi);
const agentEnd = handlers.agent_end;
if (typeof agentEnd !== "function") {
  console.error("omp guard did not register an agent_end handler");
  process.exit(1);
}
const idleCtx = { isIdle: () => true, hasPendingMessages: () => false };

// 1. A scheduled continuation is not a turn end.
await agentEnd({ willContinue: true }, idleCtx);
if (runs() !== 0) {
  console.error("willContinue=true did not gate the guard");
  process.exit(1);
}

// 2. A settle that raced a fresh run is not idle.
await agentEnd({ willContinue: false }, { isIdle: () => false, hasPendingMessages: () => false });
if (runs() !== 0) {
  console.error("isIdle()=false did not gate the guard");
  process.exit(1);
}

// 3. Queued input still to process is not a turn end.
await agentEnd({ willContinue: false }, { isIdle: () => true, hasPendingMessages: () => true });
if (runs() !== 0) {
  console.error("hasPendingMessages()=true did not gate the guard");
  process.exit(1);
}

// 4. All three agree: idle. A blind turn runs the guard and sends the typed
// turn-end-guard follow-up.
await agentEnd({ willContinue: false }, idleCtx);
if (runs() !== 1) {
  console.error(`idle settle did not run the guard: runs=${runs()}`);
  process.exit(1);
}
if (!prompt.startsWith("\u2063FIRSTMATE_OP: v1 turn-end-guard: ")) {
  console.error(`untyped guard follow-up: ${prompt}`);
  process.exit(1);
}
if (!prompt.includes("TURN WOULD END BLIND")) {
  console.error(`missing guard body: ${prompt}`);
  process.exit(1);
}

// 5. The follow-up itself settles the agent; that re-entrant settle consumes the
// latch and must NOT re-run the guard.
prompt = "";
await agentEnd({ willContinue: false }, idleCtx);
if (runs() !== 1) {
  console.error("follow-up latch did not suppress the re-entrant settle");
  process.exit(1);
}
if (prompt !== "") {
  console.error(`latch settle unexpectedly prompted: ${prompt}`);
  process.exit(1);
}

// 6. A later genuine settle runs the guard again.
await agentEnd({ willContinue: false }, idleCtx);
if (runs() !== 2) {
  console.error(`post-latch settle did not run the guard: runs=${runs()}`);
  process.exit(1);
}
EOF
  )
  status=$?
  expect_code 0 "$status" "omp guard settle-triple gating/latch behavior is wrong"$'\n'"$out"
  pass "omp guard runs only on an idle settle triple and latches its own follow-up"
}

test_omp_guard_settle_triple_gates_and_latches
