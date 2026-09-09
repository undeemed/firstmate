#!/usr/bin/env bash
# tests/fm-secondmate-rename.test.sh - offline secondmate rename.
#
# Every case runs against a fixture parent home, a fixture mate home, a fixture
# treehouse pool file, and a fixture code root holding a copy of the live-board
# home map. The real pool state and the real tracked map are never opened.
set -u

# shellcheck source=tests/lib.sh disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-secondmate-rename)
RENAME="$ROOT/bin/fm-secondmate-rename.sh"

OLD_ID=alpha-mate-a1
NEW_ID=beta-mate-b2

# A tmux stand-in with exactly the two reads the recovery-grade agent classifier
# makes: the window inventory, and the pane's current command. An empty
# FAKE_WINDOWS means the recorded window is gone, which is what an exited mate
# leaves behind once its endpoint is closed.
make_probe_tmux() { # <dir>
	local dir=$1 fakebin
	fakebin=$(fm_fakebin "$dir")
	cat >"$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
case "${1:-}" in
  list-windows)
    [ -z "${FAKE_WINDOWS:-}" ] || printf '%s\n' "$FAKE_WINDOWS"
    exit 0
    ;;
  display-message)
    case "$*" in
      *'pane_current_command'*) printf '%s\n' "${FAKE_COMMAND:-bash}" ;;
      *) printf '\n' ;;
    esac
    exit 0
    ;;
esac
exit 1
SH
	chmod +x "$fakebin/tmux"
	printf '%s\n' "$fakebin"
}

# Build a parent home, a mate home, a pool state file, and a code root. Sets
# PARENT, MATE, POOL, CODE, FAKEBIN.
setup_fixture() { # <name>
	local name=$1
	PARENT="$TMP_ROOT/$name/parent"
	POOL="$TMP_ROOT/$name/pool"
	MATE="$POOL/2/firstmate"
	CODE="$TMP_ROOT/$name/code"

	mkdir -p "$PARENT/state/.secondmate-nudge-pending" "$PARENT/data/$OLD_ID" "$CODE/bin"
	fm_make_secondmate_home "$OLD_ID" "$MATE"
	mkdir -p "$MATE/projects/oldproj"
	printf 'clone marker\n' >"$MATE/projects/oldproj/README.md"

	fm_write_secondmate_meta "$PARENT/state/$OLD_ID.meta" "$MATE" "firstmate:fm-$OLD_ID" oldproj
	printf 'backend=tmux\n' >>"$PARENT/state/$OLD_ID.meta"
	printf 'tasktmp=/tmp/fm-%s\n' "$OLD_ID" >>"$PARENT/state/$OLD_ID.meta"

	# Sidecars in both shapes the fleet writes, plus history that must survive.
	printf 'working [key=setup]: first turn under %s\n' "$OLD_ID" >"$PARENT/state/$OLD_ID.status"
	printf 'seen\n' >"$PARENT/state/.seen-${OLD_ID}_status"
	printf 'surfaced\n' >"$PARENT/state/.hb-surfaced-$OLD_ID"
	printf '0\n' >"$PARENT/state/.$OLD_ID.open-decisions-cursor"
	{
		printf 'id=%s\n' "$OLD_ID"
		printf 'selector=fm-%s\n' "$OLD_ID"
		printf 'home=%s\n' "$MATE"
	} >"$PARENT/state/.secondmate-nudge-pending/$OLD_ID.pending"

	# A neighbouring task whose own history quotes the old id: it is history, so
	# neither its name nor its contents may change.
	fm_write_meta "$PARENT/state/neighbour.meta" "window=firstmate:fm-neighbour" "kind=ship" "home=$MATE"
	printf 'done: handed the %s report over\n' "$OLD_ID" >"$PARENT/state/neighbour.status"

	printf -- '- %s - fixture domain (home: %s; scope: fixture; projects: oldproj; added 2026-07-13)\n' \
		"$OLD_ID" "$MATE" >"$PARENT/data/secondmates.md"
	printf -- '- oldproj [direct-PR +yolo] - fixture project (added 2026-07-13)\n' \
		>"$PARENT/data/projects.md"
	printf '# charter for %s\n' "$OLD_ID" >"$PARENT/data/$OLD_ID/brief.md"
	printf '# charter for %s\n' "$OLD_ID" >"$MATE/data/charter.md"
	printf -- '- [ ] some-item - fixture work (repo: oldproj) (kind: ship)\n' >>"$MATE/data/backlog.md"

	mkdir -p "$POOL"
	: >"$POOL/treehouse-state.lock"
	cat >"$POOL/treehouse-state.json" <<EOF
{
  "worktrees": [
    {"name": "1", "path": "$POOL/1/firstmate", "leased": true, "lease_holder": "other-mate-o1"},
    {"name": "2", "path": "$MATE", "leased": true, "lease_holder": "$OLD_ID"}
  ]
}
EOF

	cat >"$CODE/bin/fm-live-board.py" <<EOF
HOMES = {
    "oldproj": Path("$MATE"),
}
EOF

	FAKEBIN=$(make_probe_tmux "$TMP_ROOT/$name/fake")
}

run_rename() { # <args...>
	FM_HOME="$PARENT" FM_ROOT_OVERRIDE="$CODE" PATH="$FAKEBIN:$PATH" \
		FAKE_WINDOWS="${FAKE_WINDOWS:-}" FAKE_COMMAND="${FAKE_COMMAND:-bash}" \
		"$RENAME" "$@" 2>&1
}

# A content-and-shape manifest of a tree, so "wrote nothing" is provable.
manifest() { # <dir>
	local path
	find "$1" | LC_ALL=C sort | while IFS= read -r path; do
		if [ -f "$path" ]; then
			printf '%s %s\n' "$path" "$(cksum <"$path")"
		else
			printf '%s dir\n' "$path"
		fi
	done
}

test_rename_moves_every_live_record() {
	local out rc=0
	setup_fixture rename-happy
	out=$(run_rename "$OLD_ID" "$NEW_ID" --project oldproj newproj) || rc=$?
	expect_code 0 "$rc" "rename of an exited mate"

	assert_absent "$PARENT/state/$OLD_ID.meta" "old task record survived the rename"
	assert_present "$PARENT/state/$NEW_ID.meta" "new task record was not created"
	assert_grep "endpoint_task_id=$NEW_ID" "$PARENT/state/$NEW_ID.meta" "endpoint_task_id was not rewritten"
	assert_grep "tasktmp=/tmp/fm-$NEW_ID" "$PARENT/state/$NEW_ID.meta" "tasktmp was not rewritten"
	assert_grep "projects=newproj" "$PARENT/state/$NEW_ID.meta" "projects= was not rewritten"

	assert_present "$PARENT/state/.seen-${NEW_ID}_status" "the seen sidecar did not move"
	assert_present "$PARENT/state/.hb-surfaced-$NEW_ID" "the heartbeat sidecar did not move"
	assert_present "$PARENT/state/.$NEW_ID.open-decisions-cursor" "the decisions cursor did not move"
	assert_absent "$PARENT/state/.secondmate-nudge-pending/$OLD_ID.pending" "the old nudge marker survived"
	assert_grep "id=$NEW_ID" "$PARENT/state/.secondmate-nudge-pending/$NEW_ID.pending" \
		"the nudge marker id was not rewritten"
	assert_grep "selector=fm-$NEW_ID" "$PARENT/state/.secondmate-nudge-pending/$NEW_ID.pending" \
		"the nudge marker selector was not rewritten"

	assert_grep "$NEW_ID" "$MATE/.fm-secondmate-home" "the home identity marker was not rewritten"
	assert_grep "- $NEW_ID " "$PARENT/data/secondmates.md" "the routing record id was not rewritten"
	assert_grep "projects: newproj;" "$PARENT/data/secondmates.md" "the routing record project was not rewritten"
	assert_grep "- newproj [" "$PARENT/data/projects.md" "the project registry entry was not rewritten"
	assert_grep '"newproj": Path(' "$CODE/bin/fm-live-board.py" "the live-board home map was not rewritten"
	assert_grep "(repo: newproj)" "$MATE/data/backlog.md" "the mate's own repo: fields were not rewritten"
	assert_present "$MATE/projects/newproj/README.md" "the project clone did not move"
	assert_absent "$MATE/projects/oldproj" "the old project clone survived"
	assert_grep "$NEW_ID" "$PARENT/data/$NEW_ID/brief.md" "the charter brief was not rewritten"
	assert_grep "$NEW_ID" "$MATE/data/charter.md" "the home charter was not rewritten"

	assert_grep "\"lease_holder\": \"$NEW_ID\"" "$POOL/treehouse-state.json" "the treehouse lease was not re-keyed"
	assert_grep '"lease_holder": "other-mate-o1"' "$POOL/treehouse-state.json" "another mate's lease was disturbed"

	assert_contains "$out" "bin/fm-spawn.sh $NEW_ID $MATE --secondmate" "the relaunch command was not printed"
	pass "rename moves every live record and re-keys the lease"
}

test_history_survives_the_rename() {
	local rc=0
	setup_fixture rename-history
	run_rename "$OLD_ID" "$NEW_ID" --project oldproj newproj >/dev/null || rc=$?
	expect_code 0 "$rc" "rename of an exited mate"

	assert_grep "working [key=setup]: first turn under $OLD_ID" "$PARENT/state/$NEW_ID.status" \
		"the transcript's own history was rewritten instead of inherited"
	assert_grep "note: renamed from $OLD_ID at " "$PARENT/state/$NEW_ID.status" \
		"the rename record was not appended to the new transcript"
	assert_grep "done: handed the $OLD_ID report over" "$PARENT/state/neighbour.status" \
		"a neighbouring task's history was rewritten"
	assert_present "$PARENT/state/neighbour.meta" "a neighbouring task's record was moved"
	pass "history keeps the old id and only the transcript's file name moves"
}

test_dry_run_writes_nothing() {
	local out rc=0 before after
	setup_fixture rename-dry
	before=$(manifest "$TMP_ROOT/rename-dry")
	out=$(run_rename "$OLD_ID" "$NEW_ID" --project oldproj newproj --dry-run) || rc=$?
	after=$(manifest "$TMP_ROOT/rename-dry")
	expect_code 0 "$rc" "dry run"
	[ "$before" = "$after" ] || fail "dry run changed the fixture tree"

	assert_contains "$out" "$PARENT/state/$OLD_ID.meta -> $PARENT/state/$NEW_ID.meta" \
		"the dry run did not list the task record move"
	assert_contains "$out" "$MATE/projects/oldproj -> $MATE/projects/newproj" \
		"the dry run did not list the project clone move"
	assert_contains "$out" "$POOL/treehouse-state.json" "the dry run did not list the lease edit"
	assert_contains "$out" "bin/fm-control.sh $OLD_ID exit" "the dry run did not print the exit command"
	assert_contains "$out" "dry run: nothing was written" "the dry run did not say it wrote nothing"
	pass "dry run lists every path and writes nothing"
}

test_refuses_while_the_agent_is_live() {
	local out rc=0
	setup_fixture rename-live
	FAKE_WINDOWS="fm-$OLD_ID" FAKE_COMMAND=claude
	export FAKE_WINDOWS FAKE_COMMAND
	out=$(run_rename "$OLD_ID" "$NEW_ID") || rc=$?
	unset FAKE_WINDOWS FAKE_COMMAND
	[ "$rc" -ne 0 ] || fail "rename proceeded while the mate was still running"
	assert_contains "$out" "not proven exited" "the refusal did not name the live endpoint"
	assert_contains "$out" "bin/fm-control.sh $OLD_ID exit" "the refusal did not print the exit command"
	assert_present "$PARENT/state/$OLD_ID.meta" "the task record moved despite the refusal"
	assert_absent "$PARENT/state/$NEW_ID.meta" "a new task record was created despite the refusal"
	pass "a live agent refuses the rename and names the exit command"
}

test_refuses_while_the_busy_record_reads_busy() {
	local out rc=0
	setup_fixture rename-busy
	printf 'v1 gen=abc seq=3 state=busy source=tmux-wire event=submit ts=1788901990\n' \
		>"$PARENT/state/$OLD_ID.busy-state"
	out=$(run_rename "$OLD_ID" "$NEW_ID") || rc=$?
	[ "$rc" -ne 0 ] || fail "rename proceeded while the mate recorded a busy turn"
	assert_contains "$out" "busy turn" "the refusal did not name the busy record"
	assert_present "$PARENT/state/$OLD_ID.meta" "the task record moved despite the refusal"
	pass "a busy record refuses the rename"
}

test_refuses_when_another_id_contains_the_old_id() {
	local out rc=0
	setup_fixture rename-ambiguous
	fm_write_meta "$PARENT/state/$OLD_ID-scout.meta" "window=firstmate:fm-scout" "kind=ship" "home=$MATE"
	out=$(run_rename "$OLD_ID" "$NEW_ID") || rc=$?
	[ "$rc" -ne 0 ] || fail "rename proceeded with an ambiguous sibling id"
	assert_contains "$out" "contains $OLD_ID" "the refusal did not name the ambiguous sibling"
	assert_present "$PARENT/state/$OLD_ID.meta" "the task record moved despite the refusal"
	pass "a sibling id containing the old id refuses the rename"
}

test_refuses_when_the_lease_belongs_to_another_mate() {
	local out rc=0
	setup_fixture rename-lease
	cat >"$POOL/treehouse-state.json" <<EOF
{"worktrees": [{"name": "2", "path": "$MATE", "leased": true, "lease_holder": "someone-else-x9"}]}
EOF
	out=$(run_rename "$OLD_ID" "$NEW_ID") || rc=$?
	[ "$rc" -ne 0 ] || fail "rename re-keyed a lease held by another mate"
	assert_contains "$out" "someone-else-x9" "the refusal did not name the lease holder"
	assert_grep '"lease_holder": "someone-else-x9"' "$POOL/treehouse-state.json" "the foreign lease was rewritten"
	pass "a lease held by another mate refuses the rename"
}

command -v jq >/dev/null 2>&1 || {
	echo "skip: jq not found (required to read the treehouse lease)"
	exit 0
}

test_rename_moves_every_live_record
test_history_survives_the_rename
test_dry_run_writes_nothing
test_refuses_while_the_agent_is_live
test_refuses_while_the_busy_record_reads_busy
test_refuses_when_another_id_contains_the_old_id
test_refuses_when_the_lease_belongs_to_another_mate

echo "ALL TESTS PASSED"
