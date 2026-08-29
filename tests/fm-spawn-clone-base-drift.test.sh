#!/usr/bin/env bash
# Regression tests for fm-spawn's stale-clone refusal.
#
# Firstmate writes a ship or scout brief from the project CLONE, so a clone that
# is silently behind its remote yields instructions describing files that changed
# underneath it - measured live across a fleet whose clones ran 2 to 1822 commits
# behind. The pooled-worktree refresh (tests/fm-spawn-pool-base-freshen.test.sh)
# starts the worker on origin's tip but cannot repair an already-written brief.
# These tests drive the real spawn path with a fake terminal and prove the
# refusal, the read-only treatment of unlanded work, the warn-and-launch
# degradation when the fetch fails, and the one-fetch-per-spawn cost.
set -u

# shellcheck source=tests/spawn-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/spawn-helpers.sh"

fm_git_identity
TMP_ROOT=$(fm_test_tmproot fm-spawn-clone-base-drift)
REAL_GIT=$(command -v git)

# The shared fake terminal plus a fake git that appends every `git -C <dir>
# fetch` to FM_TEST_GIT_LOG (so a case can count the clone's fetches) and fails
# that fetch when <dir> is FM_TEST_GIT_FETCH_FAIL_DIR (so a case can take origin
# away from the clone alone, leaving the pooled worktree's own refresh working).
# Everything else is the real git.
make_spawn_fakebin() {
	local dir=$1 fakebin
	fakebin=$(fm_spawn_fake_terminal "$dir")
	cat >"$fakebin/git" <<SH
#!/usr/bin/env bash
set -u
real_git=$REAL_GIT
SH
	cat >>"$fakebin/git" <<'SH'
if [ "${1:-}" = -C ] && [ "${3:-}" = fetch ]; then
  [ -z "${FM_TEST_GIT_LOG:-}" ] || printf 'fetch\t%s\n' "$2" >>"$FM_TEST_GIT_LOG"
  if [ -n "${FM_TEST_GIT_FETCH_FAIL_DIR:-}" ] && [ "$2" = "$FM_TEST_GIT_FETCH_FAIL_DIR" ]; then
    echo "fatal: unable to access origin (simulated network blip)" >&2
    exit 128
  fi
fi
exec "$real_git" "$@"
SH
	chmod +x "$fakebin/git"
	printf '%s\n' "$fakebin"
}

# A clone one commit behind its origin, plus a pooled worktree of that clone
# sitting on the clone's own HEAD, so the only drift under test is the clone's.
# Sets the case globals fm_spawn_run reads, plus CASE_DIR and CLONE_HEAD.
make_case() {
	local name=$1 id=$2 seed origin
	CASE_DIR="$TMP_ROOT/$name"
	HOME_DIR="$CASE_DIR/home"
	PROJECT_DIR="$CASE_DIR/project"
	POOL_DIR="$CASE_DIR/pool"
	FAKEBIN_DIR=$(make_spawn_fakebin "$CASE_DIR/fake")
	seed="$CASE_DIR/seed"
	origin="$CASE_DIR/origin.git"
	fm_spawn_home "$HOME_DIR" "$id"

	git init --quiet -b main "$seed"
	printf 'base\n' >"$seed/README.md"
	git -C "$seed" add README.md
	git -C "$seed" commit -qm initial
	git clone --quiet --bare "$seed" "$origin"
	git clone --quiet "file://$origin" "$PROJECT_DIR"
	CLONE_HEAD=$(git -C "$PROJECT_DIR" rev-parse HEAD)
	git -C "$PROJECT_DIR" worktree add --quiet --detach "$POOL_DIR" "$CLONE_HEAD"

	# Advance origin past the clone: the drift every case starts from.
	printf 'renamed concurrency group\n' >"$seed/deploy.yml"
	git -C "$seed" add deploy.yml
	git -C "$seed" commit -qm advance-main
	git -C "$seed" push --quiet "file://$origin" main
}

# CBD-1: a ship or scout spawn whose clone is behind origin and carries unlanded
# work stops before any endpoint exists, names the drift and the guarded repair,
# and leaves every uncommitted byte of that clone exactly as it found it.
test_behind_clone_with_unlanded_work_refuses_untouched() {
	local id out status before contract
	for contract in ship scout; do
		id="clone-drift-refusal-$contract-c1"
		make_case "behind-dirty-$contract" "$id"
		printf 'keep this unlanded work\n' >"$PROJECT_DIR/uncommitted.txt"
		git -C "$PROJECT_DIR" add uncommitted.txt
		printf 'and this uncommitted edit\n' >>"$PROJECT_DIR/README.md"
		before="$CLONE_HEAD $(git -C "$PROJECT_DIR" status --porcelain)"

		if [ "$contract" = scout ]; then
			out=$(fm_spawn_run "$id" --scout)
		else
			out=$(fm_spawn_run "$id" --mode no-mistakes --yolo off)
		fi
		status=$?
		[ "$status" -ne 0 ] || fail "$contract spawn succeeded from a clone behind origin"
		assert_contains "$out" "is 1 commit(s) behind origin/main" \
			"the $contract refusal did not quantify the clone's drift"
		assert_contains "$out" "bin/fm-fleet-sync.sh" \
			"the $contract refusal did not name the guarded sync path"
		[ ! -e "$HOME_DIR/state/$id.meta" ] ||
			fail "a refused $contract spawn still published task metadata"
		# One snapshot covers every way the clone could have been touched: a moved
		# HEAD, a discarded edit, and a stash (which would empty the porcelain).
		[ "$before" = "$(git -C "$PROJECT_DIR" rev-parse HEAD) $(git -C "$PROJECT_DIR" status --porcelain)" ] ||
			fail "the $contract refusal modified the clone carrying unlanded work"
	done
	pass "ship and scout spawns from a stale clone refuse before an endpoint exists, never modifying its unlanded work"
}

# CBD-2: syncing the clone the way the refusal instructs clears it, and the
# launching spawn pays at most one fetch of that clone.
test_synced_clone_launches_within_one_fetch_per_spawn() {
	local id out log launched_fetches
	id='clone-drift-sync-c2'
	make_case behind-then-synced "$id"
	log="$CASE_DIR/git-fetch.log"

	out=$(fm_spawn_run "$id" --mode no-mistakes --yolo off)
	assert_contains "$out" "is 1 commit(s) behind origin/main" \
		"a clean clone behind origin did not refuse"

	git -C "$PROJECT_DIR" fetch --quiet origin
	git -C "$PROJECT_DIR" merge --quiet --ff-only origin/main
	: >"$log"
	out=$(FM_TEST_GIT_LOG="$log" fm_spawn_run "$id" --mode no-mistakes --yolo off)
	assert_contains "$out" "spawned $id" "a synced clone did not launch"
	# An upper bound, not a pinned cost: the check may become free if a later
	# refactor folds it into an existing fetch, but it must never add a second
	# forge round-trip to a spawn.
	launched_fetches=$(grep -c "^fetch	$PROJECT_DIR\$" "$log")
	[ "$launched_fetches" -le 1 ] ||
		fail "a launching spawn fetched the clone $launched_fetches times, expected at most 1"
	pass "syncing the clone clears the refusal, at no more than one clone fetch per spawn"
}

# CBD-3: an unreachable origin during the clone's own fetch warns and launches;
# a network blip is not a reason to hold work.
test_failed_clone_fetch_warns_and_launches() {
	local id out status
	id='clone-drift-offline-c3'
	make_case offline-fetch "$id"

	out=$(FM_TEST_GIT_FETCH_FAIL_DIR="$PROJECT_DIR" fm_spawn_run "$id" --mode no-mistakes --yolo off)
	status=$?
	expect_code 0 "$status" "a failed clone fetch should not block the spawn"
	assert_contains "$out" "launching without a base-freshness check" \
		"a failed clone fetch did not warn"
	assert_contains "$out" "spawned $id" "the spawn did not complete after the warning"
	pass "a failed clone fetch degrades to a warning and launches the worker"
}

test_behind_clone_with_unlanded_work_refuses_untouched
test_synced_clone_launches_within_one_fetch_per_spawn
test_failed_clone_fetch_warns_and_launches

echo "# all fm-spawn-clone-base-drift tests passed"
