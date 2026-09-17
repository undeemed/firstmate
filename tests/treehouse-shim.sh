#!/usr/bin/env bash
# tests/treehouse-shim.sh - installed as `treehouse` on the suite's PATH by
# tests/lib.sh, which owns the reason this exists.
#
# Point a FIXTURE repository's worktree pool at the suite's own fixture root,
# then hand over to the real binary. Only repositories under the temp area
# fixtures are built in are touched: a treehouse call made from a real checkout
# (firstmate's own, say) must keep that checkout's real pool configuration.
set -u

real=${FM_TEST_TREEHOUSE_BIN:?FM_TEST_TREEHOUSE_BIN unset}
# Exec'ing this shim again would loop forever, which reads as a hung suite.
[ "$(readlink -f "$real")" != "$(readlink -f "${BASH_SOURCE[0]}")" ] ||
  { echo "treehouse-shim: FM_TEST_TREEHOUSE_BIN points at this shim" >&2; exit 1; }
root=${FM_TEST_TREEHOUSE_ROOT:?FM_TEST_TREEHOUSE_ROOT unset}
export TREEHOUSE_NO_UPDATE_CHECK=1

fixture_repo() {
	local repo tmp
	repo=$(git rev-parse --show-toplevel 2>/dev/null) || return 1
	[ -n "$repo" ] || return 1
	repo=$(cd "$repo" 2>/dev/null && pwd -P) || return 1
	tmp=$(cd "${TMPDIR:-/tmp}" 2>/dev/null && pwd -P) || return 1
	case "$repo" in
	"$tmp"/*) printf '%s\n' "$repo" ;;
	*) return 1 ;;
	esac
}

if repo=$(fixture_repo); then
	config="$repo/treehouse.toml"
	staged="$config.fm-test.$$"
	{
		[ -f "$config" ] && grep -v '^[[:space:]]*root[[:space:]]*=' "$config"
		printf 'root = "%s"\n' "$root"
	} >"$staged" && mv "$staged" "$config"
	rm -f "$staged"
	# Local-only exclude, so a fixture's `git status` stays as clean as it was.
	gitdir=$(git -C "$repo" rev-parse --path-format=absolute --git-common-dir 2>/dev/null) || gitdir=
	if [ -n "$gitdir" ] && mkdir -p "$gitdir/info" 2>/dev/null; then
		grep -qxF 'treehouse.toml' "$gitdir/info/exclude" 2>/dev/null ||
			printf 'treehouse.toml\n' >>"$gitdir/info/exclude"
	fi
fi

exec "$real" "$@"
