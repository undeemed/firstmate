#!/usr/bin/env bash
# Behavioral coverage for extensions/fm-swarms-platform-guard.ts, the
# PreToolUse seatbelt every pi/omp crewmate loads (fm-spawn.sh, __PIGUARD__).
# The extension is TypeScript; node >= 22.6 strips types natively, and bun is
# the fallback runtime. Assertions: each rule blocks what it names, nothing
# else, and the whole guard is inert outside a swarms-platform checkout.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-swarms-platform-guard)
GUARD="$ROOT/extensions/fm-swarms-platform-guard.ts"
[ -f "$GUARD" ] || fail "guard missing at $GUARD"

RUNNER=
if command -v node >/dev/null 2>&1 && node -e 'const [a,b]=process.versions.node.split(".").map(Number); process.exit((a>22||(a===22&&b>=6))?0:1)'; then
  RUNNER=node
elif command -v bun >/dev/null 2>&1; then
  RUNNER=bun
else
  fail "node >= 22.6 or bun is required to run the TypeScript guard"
fi

cat > "$TMP_ROOT/harness.mts" <<TS
import guard from ${GUARD@Q};
let handler: any;
guard({ on: (_e: string, h: any) => { handler = h; } } as any);
const inRepo = { cwd: "/tmp/.treehouse/swarms-platform-x/3/swarms-platform" };
const outside = { cwd: "/tmp/Dev/other-project" };
const call = (input: Record<string, unknown>, ctx: unknown, tool = "bash") =>
  handler({ toolName: tool, input }, ctx);
const rows: string[] = [];
const check = (label: string, r: any, wantBlock: boolean, wantReason?: RegExp) => {
  const blocked = !!(r && r.block);
  let ok = blocked === wantBlock;
  if (ok && wantBlock && wantReason && !wantReason.test(r.reason || "")) ok = false;
  rows.push((ok ? "ok" : "FAIL") + " " + label + (ok ? "" : " -> " + JSON.stringify(r)));
};
const backend = /backend infrastructure/;
// rule 4: backend infrastructure
for (const c of [
  "npx supabase start", "pnpm supabase:start", "pnpm run supabase:reset",
  "cd x && timeout 300 npx supabase start 2>&1 | tail -8", "supabase db reset --linked",
  "npx supabase migration up", "supabase link --project-ref abc",
  "docker run -d --name pg postgres:15", "docker compose -f supabase.yml up -d",
  "docker rm -f supabase_db_swarms-shared", "docker exec -i supabase_db_swarms-shared psql -U postgres",
  "psql postgresql://postgres:postgres@127.0.0.1:54322/postgres -c 'drop table x'",
]) check("blocks: " + c, call({ command: c }, inRepo), true, backend);
for (const c of [
  "npx supabase status", "pnpm dev", "pnpm exec tsc --noEmit", "docker ps", "git status",
  "curl http://127.0.0.1:54321/rest/v1/users", "docker compose -f sb.yml up -d",
  "grep -r supabase app/", "cat .env.local",
]) check("allows: " + c, call({ command: c }, inRepo), false);
// rules 1-3 still hold
check("blocks vercel.json edit", call({ path: "vercel.json" }, inRepo, "edit"), true, /vercel\\.json/);
check("blocks --no-verify", call({ command: "git commit --no-verify -m x" }, inRepo), true, /no-verify/);
check("blocks force push", call({ command: "git push --force origin b" }, inRepo), true, /force/);
check("blocks non-WARP title", call({ command: "gh pr create --title 'feat: x' -b y" }, inRepo), true, /WARP/);
check("allows WARP title", call({ command: "gh pr create --title '[STYL][Footer][x]' -b y" }, inRepo), false);
// scope
check("inert outside swarms-platform", call({ command: "npx supabase start" }, outside), false);
check("inert outside for vercel.json", call({ path: "vercel.json" }, outside, "edit"), false);
console.log(rows.join("\\n"));
process.exit(rows.some(r => r.startsWith("FAIL")) ? 1 : 0);
TS

if [ "$RUNNER" = node ]; then
  node "$TMP_ROOT/harness.mts" > "$TMP_ROOT/out" 2> "$TMP_ROOT/err"
else
  bun run "$TMP_ROOT/harness.mts" > "$TMP_ROOT/out" 2> "$TMP_ROOT/err"
fi
rc=$?
if [ "$rc" -ne 0 ]; then
  cat "$TMP_ROOT/out" "$TMP_ROOT/err" >&2
  fail "guard behaviour mismatch (runner $RUNNER, exit $rc)"
fi
assert_no_grep "FAIL" "$TMP_ROOT/out" "no failing rows"
n=$(grep -c '^ok ' "$TMP_ROOT/out")
[ "$n" -ge 28 ] || fail "expected >= 28 checks, saw $n"

pass "swarms-platform guard ($n checks via $RUNNER)"
