#!/usr/bin/env bash
# Manual end-to-end evidence driver for the forge write audit log
# (branch fm/fm-forge-write-audit-log-a3, target dd4d692).
#
# Runs the real bin/fm-pr-merge.sh from the worktree against a sandbox home
# in /tmp, with gh/gh-axi replaced by recording mocks, and shows the log an
# operator would actually read. Five scenarios:
#   A. happy GitHub merge  - log written, header states the log's own limit,
#      snapshot taken by the forge mock proves the record existed BEFORE the call,
#      and state/ contains no pr-merge-audit.log (old log superseded, not written)
#   B. forge merge crashes - non-zero exit, yet the log line is already there
#   C. unwritable log      - merge refuses (exit 1), forge never called
#   D. secret exclusion    - a secret-shaped argument reaches the forge call
#      but never the log; nor does an environment credential
#   E. second write same home - append-only: one header, two records
set -u
ROOT=${1:?usage: manual-e2e-driver.sh <worktree-root>}
SANDBOX=$(mktemp -d /tmp/fm-forge-audit-e2e.XXXXXX)
trap 'rm -rf "$SANDBOX"' EXIT

make_home() { # <name> -> echoes home dir
	local home="$SANDBOX/$1"
	mkdir -p "$home/state" "$home/fakebin" "$home/wt"
	printf '%s\n' "window=fm-task-x1" "worktree=$home/wt" "project=$home/project" \
		"kind=ship" "mode=no-mistakes" >"$home/state/task-x1.meta"
	printf '{"commits":1,"changed_files":3,"head":{"ref":"fm/task-x1"},"body":""}\n' >"$home/pull.json"
	# gh-axi mock: records every invocation; copies the audit log AT CALL TIME.
	cat >"$home/fakebin/gh-axi" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FM_TEST_GH_AXI_LOG"
[ -z "${FM_TEST_AUDIT_SNAPSHOT:-}" ] || cp "$FM_STATE_OVERRIDE/forge-write-audit.log" "$FM_TEST_AUDIT_SNAPSHOT" 2>/dev/null || :
[ ! -e "$FM_HOME/gh-axi-merge-fails" ] || { case "${1:-} ${2:-}" in "pr merge") echo "error: connection reset mid-flight" >&2; exit 1;; esac; }
exit 0
SH
	# gh mock: answers the REST head read and the pulls payload.
	cat >"$home/fakebin/gh" <<SH
#!/usr/bin/env bash
if [ "\${1:-}" = api ]; then
  case " \$* " in *" --jq .head.sha "*) echo 9999999999999999999999999999999999999999; exit 0;; esac
  case "\${2:-}" in */pulls/*) cat "$home/pull.json"; exit 0;; esac
fi
exit 0
SH
	chmod +x "$home/fakebin/gh-axi" "$home/fakebin/gh"
	: >"$home/gh-axi.log"
	printf '%s\n' "$home"
}

run_merge() { # <home> <args...>
	local home=$1
	shift
	FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" \
		FM_TEST_GH_AXI_LOG="$home/gh-axi.log" \
		FM_TEST_AUDIT_SNAPSHOT="$home/audit-at-call" \
		PATH="$home/fakebin:$PATH" "$ROOT/bin/fm-pr-merge.sh" "$@"
}

banner() { printf '\n=== %s ===\n' "$1"; }

banner "A. happy GitHub merge: the write is recorded before the forge is called"
HOME_A=$(make_home home-a)
run_merge "$HOME_A" task-x1 https://github.com/example/repo/pull/31
echo "exit=$?"
echo "--- forge invocations (gh-axi.log):"
cat "$HOME_A/gh-axi.log"
echo "--- state/ contents (no pr-merge-audit.log: the old log is superseded, not written):"
ls "$HOME_A/state/"
echo "--- state/forge-write-audit.log via cat -A (^I = tab, \$ = line end):"
cat -A "$HOME_A/state/forge-write-audit.log"
echo "--- the log as the gh-axi mock saw it AT CALL TIME (proves write-before-call):"
cat "$HOME_A/audit-at-call"

banner "B. forge merge crashes mid-flight: evidence of the attempt survives"
HOME_B=$(make_home home-b)
touch "$HOME_B/gh-axi-merge-fails"
run_merge "$HOME_B" task-x1 https://github.com/example/repo/pull/32
echo "exit=$? (non-zero: the merge really failed)"
echo "--- yet the audit log already holds the attempt:"
grep 'pull/32' "$HOME_B/state/forge-write-audit.log"

banner "C. unwritable log: the merge refuses rather than act unlogged"
HOME_C=$(make_home home-c)
mkdir -p "$HOME_C/state/forge-write-audit.log" # a directory: every append fails
run_merge "$HOME_C" task-x1 https://github.com/example/repo/pull/33 2>"$HOME_C/stderr"
echo "exit=$?"
echo "--- stderr:"
cat "$HOME_C/stderr"
echo "--- forge merge invocations after the refusal (must be none):"
grep -c 'pr merge' "$HOME_C/gh-axi.log" || echo "0 merge calls: the forge was never asked to act"

banner "D. a secret-shaped argument reaches the forge call but never the log"
HOME_D=$(make_home home-d)
GH_TOKEN=ghp_environmentcredential000 \
	run_merge "$HOME_D" task-x1 https://github.com/example/repo/pull/34 -- \
	--squash --auth-token=ghp_argumentcredential111
echo "exit=$?"
echo "--- the forge call really carried the secret-shaped argument (non-vacuous):"
grep -F 'auth-token' "$HOME_D/gh-axi.log"
echo "--- the audit log carries neither the argument nor the environment credential:"
grep -c 'ghp_argumentcredential111\|ghp_environmentcredential000' \
	"$HOME_D/state/forge-write-audit.log" || echo "0 matches: no credential material in the log"
echo "--- what the log does carry:"
cat "$HOME_D/state/forge-write-audit.log"

banner "E. a second write into the same home: one header, two records"
run_merge "$HOME_A" task-x1 https://github.com/example/repo/pull/35
echo "exit=$?"
echo "--- state/forge-write-audit.log via cat -A after two merges from home-a:"
cat -A "$HOME_A/state/forge-write-audit.log"
echo "--- header lines in the log (must be exactly 1):"
grep -c '^# forge writes' "$HOME_A/state/forge-write-audit.log"
