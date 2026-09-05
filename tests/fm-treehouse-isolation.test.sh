#!/usr/bin/env bash
# Tests that the behavior suite never leaves a worktree pool in the developer's
# own ~/.treehouse.
#
# A treehouse pool OUTLIVES the fixture repository it was cut from: `treehouse
# return` hands a worktree back to the pool, it does not delete the pool. Every
# suite that drove the real spawn path therefore left one permanent directory
# behind per fixture repo - 1533 of them, ~700 MB, measured 2026-09-05.
# tests/lib.sh redirects that pool into a self-cleaning fixture root; this pins
# the redirect, the cleanup, and the boundary that keeps a REAL checkout's own
# pool configuration untouched.
#
# Cases:
#   (a) a suite acquiring a real worktree lands it under the fixture root
#   (b) $HOME/.treehouse gains nothing while that suite runs
#   (c) the fixture root is gone once the suite's traps have run
#   (d) the fixture repo's `git status` is as clean as it was
#   (e) a real checkout outside the fixture area keeps its own configuration
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

command -v treehouse >/dev/null 2>&1 || {
	echo "skip: treehouse not found (nothing can leak without it)"
	exit 0
}

TMP_ROOT=$(fm_test_tmproot fm-treehouse-isolation)
HOME_POOL="$HOME/.treehouse"

pool_snapshot() {
	[ -d "$HOME_POOL" ] || {
		printf '<absent>\n'
		return 0
	}
	find "$HOME_POOL" -mindepth 1 -maxdepth 1 -printf '%f\n' | sort
}

before=$(pool_snapshot)

# A suite, run exactly as the runner runs one: its own process, sourcing
# tests/lib.sh, building a fixture repo and acquiring a real worktree from it.
cat >"$TMP_ROOT/suite.sh" <<SH
#!/usr/bin/env bash
set -u
. "$ROOT/tests/lib.sh"
case_root=\$(fm_test_tmproot fm-treehouse-isolation-case)
repo="\$case_root/project"
fm_git_init_commit "\$repo"
cd "\$repo" || exit 1
worktree=\$(treehouse get --lease --lease-holder isolation-probe 2>/dev/null) || exit 1
printf 'worktree=%s\n' "\$worktree"
printf 'fixture_root=%s\n' "\$FM_TEST_TREEHOUSE_ROOT"
printf 'status=%s\n' "\$(git -C "\$repo" status --porcelain | tr '\n' ',')"
treehouse return --force "\$worktree" >/dev/null 2>&1
SH
chmod +x "$TMP_ROOT/suite.sh"

suite_out=$(env -u FM_TEST_TREEHOUSE_ROOT "$TMP_ROOT/suite.sh") || fail "the fixture suite did not complete: $suite_out"
after=$(pool_snapshot)

worktree=${suite_out#*worktree=}
worktree=${worktree%%$'\n'*}
fixture_root=${suite_out#*fixture_root=}
fixture_root=${fixture_root%%$'\n'*}
status=${suite_out#*status=}
status=${status%%$'\n'*}

[ -n "$worktree" ] || fail "(a) the suite acquired no worktree at all"
case "$worktree" in
"$fixture_root"/*) : ;;
*) fail "(a) the suite's worktree is outside its fixture root: $worktree" ;;
esac
pass "(a) a suite acquiring a real worktree lands it under its own fixture root"

[ "$before" = "$after" ] || fail "(b) \$HOME/.treehouse changed while the suite ran:"$'\n'"$(diff <(printf '%s\n' "$before") <(printf '%s\n' "$after"))"
pass "(b) \$HOME/.treehouse is byte-for-byte unchanged by a suite that acquires worktrees"

[ ! -d "$fixture_root" ] || fail "(c) the fixture pool root survived the suite: $fixture_root"
pass "(c) the fixture pool root is removed by the suite's own trap"

[ -z "$status" ] || fail "(d) the redirect left the fixture repo dirty: $status"
pass "(d) the fixture repo's git status is as clean as it was"

# The dangerous near miss: a suite calling treehouse from a real checkout must
# not have that checkout's pool repointed at a fixture root that is about to be
# deleted.
(cd "$ROOT" && treehouse status >/dev/null 2>&1) || true
[ ! -e "$ROOT/treehouse.toml" ] || fail "(e) the redirect wrote a pool configuration into the real checkout $ROOT"
pass "(e) a treehouse call from a real checkout leaves that checkout's own configuration alone"
