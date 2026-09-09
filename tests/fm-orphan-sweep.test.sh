#!/usr/bin/env bash
# Tests for bin/fm-orphan-sweep.sh, the scheduled backstop for litter that
# outlives the records naming it.
#
# Everything here is destructive, so each case is really a test of the PROOF
# the sweep demands before it removes anything. The dangerous failure is not a
# missed orphan, it is a live mate's desktop, pool, or scratch directory taken
# away underneath it.
#
# Cases:
#   (a) a desktop no live mate records, with its display down     -> REMOVED
#   (b) the same desktop's registry line                          -> DROPPED
#   (c) a desktop a live mate records in its state                -> KEPT
#   (d) a desktop whose display is still up                       -> KEPT
#   (e) a pool whose worktrees' source repository is gone         -> REMOVED
#   (f) a pool with a worktree pointer that cannot be read       -> KEPT
#   (g) a pool whose source repository still exists               -> KEPT
#   (h) a pool treehouse still records a lease in                 -> KEPT
#   (i) a /tmp entry older than the window                        -> REMOVED
#   (j) a /tmp entry with recent activity nested inside it        -> KEPT
#   (k) a /tmp entry matching the allowlist                       -> KEPT
#   (l) a /tmp entry a live process is working in                 -> KEPT
#   (m) --dry-run                                                 -> reports, removes nothing
#   (n) a /tmp entry this user owns but cannot write to            -> KEPT, silently
#   (o) a fenced process whose cwd and profile are gone           -> STOPPED
#   (p) a fenced process with live evidence, and the real table   -> KEPT, untouched
#   (q) a pool with a relative pointer to a live source repo      -> KEPT
#   (r) a pool whose relative pointer resolves to a gone repo     -> REMOVED
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

command -v lsof >/dev/null 2>&1 || {
	echo "skip: lsof not found (the sweep refuses to remove anything without it)"
	exit 0
}

SWEEP="$ROOT/bin/fm-orphan-sweep.sh"
TMP_ROOT=$(fm_test_tmproot fm-orphan-sweep)
AGED='10 days ago'

age() { # <path>
	find "$1" -exec touch -h -d "$AGED" {} + 2>/dev/null || true
}

seed_pool() { # <pool> <source-repo-path>
	local pool=$1 source=$2
	mkdir -p "$pool/1/repo"
	printf 'gitdir: %s/.git/worktrees/repo\n' "$source" >"$pool/1/repo/.git"
	printf '{"worktrees":[{"name":"1","path":"%s/1/repo"}]}\n' "$pool" \
		>"$pool/treehouse-state.json"
}

# --- fixture ----------------------------------------------------------------

HOME_DIR="$TMP_ROOT/home"
DESKTOPS="$TMP_ROOT/desktops"
REGISTRY="$DESKTOPS/registry"
X_SOCKETS="$TMP_ROOT/x-sockets"
POOLS="$TMP_ROOT/pools"
TMP_SWEPT="$TMP_ROOT/tmp"

mkdir -p "$HOME_DIR/state" "$X_SOCKETS" "$POOLS" "$TMP_SWEPT"

for name in owned-mate dead-mate up-mate; do
	mkdir -p "$DESKTOPS/$name/chrome-profile"
	printf 'session state\n' >"$DESKTOPS/$name/chrome-profile/Cookies"
done
printf 'owned-mate\t41\ndead-mate\t42\nup-mate\t43\n' >"$REGISTRY"
fm_write_meta "$HOME_DIR/state/owned-mate.meta" 'kind=secondmate' "home=$TMP_ROOT/owned"
: >"$X_SOCKETS/X43"

seed_pool "$POOLS/dead-pool" "$TMP_ROOT/repo-that-is-gone"
seed_pool "$POOLS/leased-pool" "$TMP_ROOT/repo-that-is-gone"
printf '{"worktrees":[{"name":"1","path":"x","leased": true,"lease_holder":"mate"}]}\n' \
	>"$POOLS/leased-pool/treehouse-state.json"
seed_pool "$POOLS/half-read-pool" "$TMP_ROOT/repo-that-is-gone"
mkdir -p "$POOLS/half-read-pool/2/repo"
printf 'gitdir: %s/.git/worktrees/repo\n' "$TMP_ROOT/repo-that-is-gone" \
	>"$POOLS/half-read-pool/2/repo/.git"
mkdir -p "$TMP_ROOT/live-source/.git/worktrees/repo"
seed_pool "$POOLS/live-pool" "$TMP_ROOT/live-source"
mkdir -p "$TMP_ROOT/rel-live-source/.git/worktrees/repo"
seed_pool "$POOLS/rel-live-pool" "$TMP_ROOT/rel-live-source"
printf 'gitdir: ../../../../rel-live-source/.git/worktrees/repo\n' \
	>"$POOLS/rel-live-pool/1/repo/.git"
seed_pool "$POOLS/rel-dead-pool" "$TMP_ROOT/rel-gone-source"
printf 'gitdir: ../../../../rel-gone-source/.git/worktrees/repo\n' \
	>"$POOLS/rel-dead-pool/1/repo/.git"

mkdir -p "$TMP_SWEPT/old-junk" "$TMP_SWEPT/fresh-inside/nested" \
	"$TMP_SWEPT/.dotfile-scratch" "$TMP_SWEPT/held-dir"
printf 'stale\n' >"$TMP_SWEPT/old-junk/report.txt"
printf 'stale\n' >"$TMP_SWEPT/fresh-inside/nested/log.txt"
printf 'stale\n' >"$TMP_SWEPT/.dotfile-scratch/socket"
printf 'stale\n' >"$TMP_SWEPT/held-dir/build.log"
mkdir -p "$TMP_SWEPT/sealed-dir"
printf 'stale\n' >"$TMP_SWEPT/sealed-dir/events.ndjson"

age "$DESKTOPS"
age "$POOLS"
age "$TMP_SWEPT"
# Its owner made it unwritable on purpose; emptying it would mean changing that.
chmod 500 "$TMP_SWEPT/sealed-dir"
chmod 000 "$POOLS/half-read-pool/2/repo/.git"
# The hole a top-level mtime check would leave open: an old directory whose
# work is still going on somewhere inside it.
touch "$TMP_SWEPT/fresh-inside/nested/log.txt"

PROC_FIXTURE="$TMP_ROOT/proc"
mkdir -p "$PROC_FIXTURE/4242424" "$PROC_FIXTURE/4242425"
printf 'chromium' >"$PROC_FIXTURE/4242424/comm"
printf '1' >"$PROC_FIXTURE/4242424/ppid"
printf 'chromium\0--user-data-dir=%s\0' "$TMP_ROOT/profile-that-is-gone" \
	>"$PROC_FIXTURE/4242424/cmdline"
ln -s "$TMP_ROOT/cwd-that-is-gone (deleted)" "$PROC_FIXTURE/4242424/cwd"
printf 'caddy' >"$PROC_FIXTURE/4242425/comm"
printf '1' >"$PROC_FIXTURE/4242425/ppid"
printf 'caddy\0' >"$PROC_FIXTURE/4242425/cmdline"
ln -s "$TMP_ROOT" "$PROC_FIXTURE/4242425/cwd"

(cd "$TMP_SWEPT/held-dir" && exec sleep 300) </dev/null >/dev/null 2>&1 &
HOLDER_PID=$!
disown
sleep 0.3
kill -0 "$HOLDER_PID" 2>/dev/null || fail "setup: the holding process did not start"
cleanup_holder() {
	kill -KILL "$HOLDER_PID" 2>/dev/null || true
	# The sealed fixture is unwritable on purpose; unseal it so the shared
	# fixture cleanup can remove it.
	chmod 700 "$TMP_SWEPT/sealed-dir" 2>/dev/null || true
	fm_test_cleanup
}
trap cleanup_holder EXIT

run_sweep() {
	FM_HOME="$HOME_DIR" \
		FM_DESKTOP_ROOT="$DESKTOPS" \
		FM_DESKTOP_LEGACY_REGISTRY="$REGISTRY" \
		FM_DESKTOP_X_SOCKET_DIR="$X_SOCKETS" \
		FM_ORPHAN_SWEEP_TREEHOUSE_ROOT="$POOLS" \
		FM_ORPHAN_SWEEP_TMP_DIR="$TMP_SWEPT" \
		FM_ORPHAN_SWEEP_PROC_ROOT="$PROC_FIXTURE" \
		"$SWEEP" "$@"
}

# --- (m) dry run ------------------------------------------------------------

dry=$(run_sweep --dry-run) || fail "(m) the dry run failed: $dry"
assert_contains "$dry" "would have removed desktop $DESKTOPS/dead-mate" \
	"(m) the dry run did not report the dead desktop"
[ -d "$DESKTOPS/dead-mate" ] || fail "(m) the dry run removed the dead desktop anyway"
[ -d "$POOLS/dead-pool" ] || fail "(m) the dry run removed a pool anyway"
[ -d "$TMP_SWEPT/old-junk" ] || fail "(m) the dry run removed a tmp entry anyway"
assert_contains "$dry" "would have stopped disowned chromium (pid 4242424" \
	"(m) the dry run did not report the fenced orphan process"
[ -d "$PROC_FIXTURE/4242424" ] || fail "(m) the dry run stopped the fenced process anyway"
assert_contains "$dry" "orphan(s) in total" "(m) the dry run printed no summary"
pass "(m) --dry-run reports every orphan and removes nothing"

# --- the real sweep ---------------------------------------------------------

real_pids=$(pgrep -u "$(id -u)" -P 1 -x 'chrome|chromium|caddy|ssh-agent|websockify' 2>/dev/null || true)

out=$(run_sweep) || fail "(sweep) the sweep failed: $out"

[ ! -d "$DESKTOPS/dead-mate" ] || fail "(a) a desktop no live mate records survived"
assert_contains "$out" "removed desktop $DESKTOPS/dead-mate" \
	"(a) the sweep did not report the desktop it removed"
pass "(a) a desktop no live mate records, with its display down, is removed"

assert_no_grep 'dead-mate' "$REGISTRY" "(b) the dead desktop still reserves its display"
pass "(b) the dead desktop's registry line is dropped, returning its display number"

[ -f "$DESKTOPS/owned-mate/chrome-profile/Cookies" ] ||
	fail "(c) a desktop a live mate records was removed"
assert_grep 'owned-mate' "$REGISTRY" "(c) a live mate's registry line was dropped"
pass "(c) a desktop a live mate records in its own state is never swept"

[ -f "$DESKTOPS/up-mate/chrome-profile/Cookies" ] ||
	fail "(d) a desktop whose display is still up was removed"
pass "(d) a desktop whose display is still up is never swept"

[ ! -d "$POOLS/dead-pool" ] || fail "(e) a pool whose source repository is gone survived"
pass "(e) a pool whose worktrees have no source repository left is removed"

[ -f "$POOLS/live-pool/1/repo/.git" ] || fail "(g) a pool with a live source repository was removed"
pass "(g) a pool whose source repository still exists is never swept"

[ -d "$POOLS/half-read-pool" ] || fail "(f) a pool with an unreadable worktree pointer was removed"
pass "(f) a pool with a worktree pointer that cannot be read is left alone: unreadable is not proof"

[ -f "$POOLS/leased-pool/treehouse-state.json" ] || fail "(h) a leased pool was removed"
pass "(h) a pool treehouse still records a lease in is never swept"

[ -f "$POOLS/rel-live-pool/1/repo/.git" ] ||
	fail "(q) a pool with a relative pointer to a live source repository was removed"
pass "(q) a relative worktree pointer is resolved against its own directory, so a live pool is spared"

[ ! -d "$POOLS/rel-dead-pool" ] || fail "(r) a pool whose relative pointer resolves to a gone repository survived"
pass "(r) a relative pointer resolving to a gone source repository still proves an orphan"

[ ! -d "$TMP_SWEPT/old-junk" ] || fail "(i) an aged tmp entry survived"
pass "(i) a tmp entry older than the window, with nothing using it, is removed"

[ -f "$TMP_SWEPT/fresh-inside/nested/log.txt" ] ||
	fail "(j) a tmp entry with recent activity nested inside it was removed"
pass "(j) recency is judged by the newest file anywhere inside, not by the top-level mtime"

[ -f "$TMP_SWEPT/.dotfile-scratch/socket" ] || fail "(k) an allowlisted tmp entry was removed"
pass "(k) an allowlisted tmp entry is never swept"

[ -f "$TMP_SWEPT/held-dir/build.log" ] || fail "(l) a tmp entry a live process is working in was removed"
pass "(l) a tmp entry a live process is working in is never swept"

[ -f "$TMP_SWEPT/sealed-dir/events.ndjson" ] || fail "(n) an unwritable tmp entry was removed"
assert_not_contains "$out" "sealed-dir" \
  "(n) the sweep complained about a directory it deliberately leaves alone"
pass "(n) a tmp entry this user owns but cannot write to is left exactly as its owner set it"

[ ! -d "$PROC_FIXTURE/4242424" ] || fail "(o) a fenced process with its cwd and profile gone was not stopped"
assert_contains "$out" "stopped disowned chromium (pid 4242424" \
	"(o) the sweep did not report the process it stopped"
pass "(o) a disowned process whose cwd and profile are gone is stopped, inside the fence"

[ -d "$PROC_FIXTURE/4242425" ] || fail "(p) a fenced process with a live working directory was stopped"
assert_not_contains "$out" "4242425" "(p) the sweep reported a process it must keep"
for pid in $real_pids; do
	kill -0 "$pid" 2>/dev/null ||
		fail "(p) the fenced sweep reached the real process table (pid $pid is gone)"
done
pass "(p) the fence keeps the evidence gate and never touches the real process table"
