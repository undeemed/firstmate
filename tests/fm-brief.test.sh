#!/usr/bin/env bash
# Behavior tests for bin/fm-brief.sh.
#
# Regression coverage for the heredoc-in-command-substitution parse bug (issue
# #166): each ship-mode branch builds its Definition-of-done text with
# `VAR=$(cat <<EOF ... EOF)`. On bash < 5.2 (macOS ships 3.2) the lexer tracks
# quote state through the heredoc body while it scans for the matching `)` of
# the command substitution, so a single unescaped apostrophe anywhere in that
# body breaks parsing of the *entire rest of the script* - `bash -n` fails,
# not just the generated brief. Bash >= 5.2 parses `$(...)` with the real
# recursive parser and accepts the same text, so on modern machines `bash -n`
# alone is blind to this class; the static apostrophe guard below covers it
# independently of the ambient bash version. A plain `cat > file <<EOF ... EOF`
# (not wrapped in `$(...)`) is unaffected, so the secondmate charter block does
# not need this guard.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-brief)

# The script itself must always parse. This is the direct regression test for
# issue #166 on bash < 5.2: a stray apostrophe in any command-substitution
# heredoc body breaks `bash -n` on the whole file there, while bash >= 5.2
# accepts it - the static guard below catches it on every version.
test_script_parses() {
  bash -n "$ROOT/bin/fm-brief.sh" 2>&1 || fail "bin/fm-brief.sh fails bash -n (heredoc/quote regression)"
  pass "fm-brief.sh: bash -n succeeds"
}

# Extract every `$(cat <<EOF ... EOF)` heredoc body (quoted delimiters
# included) from a script and print any body line containing an apostrophe.
# Plain `cat > file <<EOF` heredocs are deliberately not matched: apostrophes
# are safe there on every bash version.
comsub_heredoc_apostrophes() {
  awk -v sq="'" '
    /\$\(cat <</ {
      delim = $0
      sub(/.*<<-?[ \t]*/, "", delim)
      gsub(/"/, "", delim)
      gsub(sq, "", delim)
      body = 1
      next
    }
    body && $0 == delim { body = 0; next }
    body && index($0, sq) { printf "%d: %s\n", NR, $0 }
  ' "$1"
}

# Version-independent guard for the issue-#166 class: `bash -n` above only
# fails on bash < 5.2, so an apostrophe reintroduced into one of the
# command-substitution heredoc bodies (PEER_NOTE, HERDR_SECTION, the three
# DODs) sails through the parse test on modern dev/CI machines while still
# breaking every scaffold on older bash. Assert statically that no such body
# contains an apostrophe, and prove the extractor flags a known-bad fixture so
# the guard can never go silently blind.
test_comsub_heredoc_bodies_are_apostrophe_free() {
  local fixture offenders
  mkdir -p "$TMP_ROOT/comsub-guard"
  fixture="$TMP_ROOT/comsub-guard/apostrophe-fixture.sh"
  cat > "$fixture" <<'FIXTURE'
X=$(cat <<EOF
this body carries firstmate's apostrophe
EOF
)
FIXTURE
  [ -n "$(comsub_heredoc_apostrophes "$fixture")" ] \
    || fail "apostrophe guard did not flag a known-bad fixture (extraction is blind)"
  offenders=$(comsub_heredoc_apostrophes "$ROOT/bin/fm-brief.sh")
  [ -z "$offenders" ] || fail "fm-brief.sh command-substitution heredoc body contains an apostrophe, which breaks the whole script on bash < 5.2 (issue #166); reword it: $offenders"
  pass "fm-brief.sh: command-substitution heredoc bodies are apostrophe-free"
}

test_help_includes_entire_header() {
  local help
  help=$("$ROOT/bin/fm-brief.sh" --help)
  assert_contains "$help" "Refuses to overwrite an existing brief." "fm-brief.sh --help omitted its header terminator"
  pass "fm-brief.sh: --help renders the complete header"
}

# Registry with one project per delivery mode, so each ship-mode DOD branch is
# exercised. A project absent from the registry defaults to no-mistakes.
write_registry() {
  local home=$1
  mkdir -p "$home/data"
  cat > "$home/data/projects.md" <<'EOF'
- direct-proj [direct-PR] - fixture for direct-PR mode (added 2026-07-01)
- local-proj [local-only] - fixture for local-only mode (added 2026-07-01)
EOF
}

# fm-brief.sh must exit 0 and produce a brief with no unreplaced shell
# metacharacter corruption for every ship delivery mode. This also guards
# against any *new* unescaped apostrophe or unbalanced quote later added to
# one of these DOD blocks, since a broken heredoc corrupts or empties the
# generated brief content, not just the script's own syntax.
test_ship_modes_generate_clean_briefs() {
  local home id brief status
  home="$TMP_ROOT/ship-home"
  write_registry "$home"

  for id_proj in "brief-nomistakes-a1:no-registry-proj" "brief-directpr-a2:direct-proj" "brief-localonly-a3:local-proj"; do
    id=${id_proj%%:*}
    proj=${id_proj##*:}
    FM_HOME="$home" "$ROOT/bin/fm-brief.sh" "$id" "$proj" >/dev/null 2>&1; status=$?
    expect_code 0 "$status" "fm-brief.sh $id $proj should exit 0"
    brief="$home/data/$id/brief.md"
    assert_present "$brief" "$id: brief was not scaffolded"
    assert_grep "# Definition of done" "$brief" "$id: brief missing Definition of done section"
    assert_grep "{TASK}" "$brief" "$id: brief missing the {TASK} placeholder"
    assert_no_grep "EOF" "$brief" "$id: brief leaked a heredoc EOF marker (unterminated heredoc)"
  done
  pass "fm-brief.sh: no-mistakes/direct-PR/local-only briefs generate cleanly"
}

# Pin the specific line the bug lived on: the no-mistakes DOD's no-mistakes
# reference must render as plain prose with no dangling apostrophe artifact.
test_no_mistakes_dod_wording() {
  local home id brief
  home="$TMP_ROOT/wording-home"
  mkdir -p "$home/data"
  id="brief-wording-b1"
  FM_HOME="$home" "$ROOT/bin/fm-brief.sh" "$id" some-proj >/dev/null 2>&1
  brief="$home/data/$id/brief.md"
  assert_present "$brief" "brief was not scaffolded"
  assert_grep "no-mistakes itself provides for the mechanics" "$brief" \
    "no-mistakes DOD lost its guidance-reference sentence"
  assert_no_grep "no-mistakes' own guidance" "$brief" \
    "no-mistakes DOD regressed to the apostrophe form that breaks bash -n"
  pass "fm-brief.sh: no-mistakes DOD wording avoids the apostrophe regression"
}

# All three scaffolds (ship, scout, and the secondmate charter) carry the
# peer-coordination paragraph. It self-gates on a herdr: session-context line
# inside the brief text itself, so its presence is backend-independent and safe
# to assert unconditionally. Ship and scout share the crewmate note; the
# secondmate charter carries an adapted one. The broadened scope (see who else
# is working; contact whenever it helps, not only on strict overlap/blockage) is
# asserted so a regression to the old overlap-or-blocked-only gate is caught.
test_peer_coordination_paragraph() {
  local home brief
  home="$TMP_ROOT/peer-home"
  mkdir -p "$home/data"
  FM_HOME="$home" "$ROOT/bin/fm-brief.sh" brief-peer-ship-c1 some-proj >/dev/null 2>&1
  FM_HOME="$home" "$ROOT/bin/fm-brief.sh" brief-peer-scout-c2 some-proj --scout >/dev/null 2>&1
  for brief in "$home/data/brief-peer-ship-c1/brief.md" "$home/data/brief-peer-scout-c2/brief.md"; do
    assert_present "$brief" "peer-coordination brief was not scaffolded"
    assert_grep "# Peer coordination" "$brief" "$brief: missing peer-coordination paragraph"
    assert_grep "herdr:" "$brief" "$brief: peer paragraph lost its herdr context self-gate"
    assert_grep "see who else is working" "$brief" "$brief: peer paragraph lost the broadened see-who-is-working scope"
    assert_grep "not only when your work strictly overlaps or you are blocked" "$brief" \
      "$brief: peer paragraph regressed to the overlap-or-blocked-only gate"
    assert_grep "note from brief-peer" "$brief" "$brief: peer paragraph lost the task-id sender identification"
    assert_grep "never a channel to the captain" "$brief" "$brief: peer paragraph lost the authority boundary"
  done

  # The secondmate charter carries an adapted peer-coordination section: same
  # herdr self-gate and authority rules, sender identifies by its secondmate id,
  # and its own spawned crewmates get their own notes through its scaffolds.
  FM_HOME="$home" FM_SECONDMATE_CHARTER='ops' \
    "$ROOT/bin/fm-brief.sh" brief-peer-second-c3 --secondmate --no-projects >/dev/null 2>&1
  brief="$home/data/brief-peer-second-c3/brief.md"
  assert_present "$brief" "secondmate charter was not scaffolded"
  assert_grep "# Peer coordination" "$brief" "secondmate charter missing peer-coordination section"
  assert_grep "herdr:" "$brief" "secondmate charter peer section lost its herdr context self-gate"
  assert_grep "see who else is working" "$brief" "secondmate charter peer section lost the broadened scope"
  assert_grep "note from brief-peer-second-c3" "$brief" \
    "secondmate charter peer section lost the secondmate-id sender identification"
  assert_grep "never a channel to the captain" "$brief" "secondmate charter peer section lost the authority boundary"
  assert_grep "own spawned crewmates receive their own peer-coordination notes" "$brief" \
    "secondmate charter peer section lost the crewmate-propagation note"
  pass "fm-brief.sh: ship, scout, and secondmate scaffolds carry the peer-coordination paragraph"
}

test_ship_project_memory_wording() {
  local home id brief
  home="$TMP_ROOT/project-memory-home"
  mkdir -p "$home/data"
  id="brief-memory-c1"
  FM_HOME="$home" "$ROOT/bin/fm-brief.sh" "$id" some-proj >/dev/null 2>&1
  brief="$home/data/$id/brief.md"
  assert_present "$brief" "brief was not scaffolded"
  assert_grep "Record only project knowledge useful to almost every future session." "$brief" \
    "project-memory contract lost the durable-knowledge bar"
  assert_grep "prefer a pointer to the authoritative file, command, or doc over copying the detail" "$brief" \
    "project-memory contract lost pointer-over-copy guidance"
  assert_grep "lacks \`## Maintaining this file\`, add that short self-governance section" "$brief" \
    "project-memory contract lost the self-governance add-in-same-pass rule"
  pass "fm-brief.sh: ship project-memory wording carries the AGENTS.md authoring bar"
}

test_herdr_lab_contract_is_explicit_and_complete() {
  local home id brief
  home="$TMP_ROOT/herdr-lab-home"
  mkdir -p "$home/data"
  id="brief-herdr-lab-d1"
  FM_HOME="$home" "$ROOT/bin/fm-brief.sh" "$id" firstmate --herdr-lab >/dev/null 2>&1
  brief="$home/data/$id/brief.md"
  assert_present "$brief" "Herdr lab brief was not scaffolded"
  assert_grep "# Herdr isolation - HARD SAFETY CONTRACT" "$brief" \
    "Herdr lab brief missing its hard safety contract"
  assert_grep "HERDR_LAB_HELPER='$ROOT/bin/fm-herdr-lab.sh'" "$brief" \
    "Herdr lab brief must bind the absolute Firstmate helper path"
  assert_grep "HERDR_LAB_SESSION=\$(\"\$HERDR_LAB_HELPER\" name $id)" "$brief" \
    "Herdr lab brief missing helper-owned session naming"
  assert_grep "\"\$HERDR_LAB_HELPER\" provision \"\$HERDR_LAB_SESSION\"" "$brief" \
    "Herdr lab brief missing helper-owned provisioning"
  assert_grep "\"\$HERDR_LAB_HELPER\" teardown \"\$HERDR_LAB_SESSION\"" "$brief" \
    "Herdr lab brief missing helper-owned teardown"
  assert_grep "required trailing \`--session \"\$HERDR_LAB_SESSION\"\`" "$brief" \
    "Herdr lab brief missing the per-call trailing session contract"
  assert_grep "direct \`herdr server stop\`" "$brief" \
    "Herdr lab brief missing the forbidden server-global command list"
  assert_grep "records the live default session before provisioning" "$brief" \
    "Herdr lab brief missing the before tripwire"
  assert_grep "verifies the identical fleet state after teardown" "$brief" \
    "Herdr lab brief missing the after tripwire"
  assert_no_grep "Herdr lifecycle declaration - NOT ENABLED" "$brief" \
    "Herdr lab brief retained the unguarded declaration"
  pass "fm-brief.sh: --herdr-lab emits the complete hard safety contract"
}

test_herdr_lab_contract_quotes_foreign_firstmate_path() {
  local home id brief foreign_root helper
  home="$TMP_ROOT/herdr-lab-foreign-home"
  foreign_root="$TMP_ROOT/firstmate helper's root"
  mkdir -p "$home/data"
  id="brief-herdr-lab-foreign-d2"
  helper=$(printf '%s' "$foreign_root/bin/fm-herdr-lab.sh" | sed "s/'/'\\\\''/g")
  helper="'$helper'"
  FM_HOME="$home" FM_ROOT_OVERRIDE="$foreign_root" "$ROOT/bin/fm-brief.sh" "$id" foreign --scout --herdr-lab >/dev/null 2>&1
  brief="$home/data/$id/brief.md"
  assert_grep "HERDR_LAB_HELPER=$helper" "$brief" \
    "Herdr lab brief must shell-quote an absolute Firstmate helper path"
  assert_no_grep "bin/fm-herdr-lab.sh name $id" "$brief" \
    "Herdr lab brief must not invoke a worktree-relative helper"
  pass "fm-brief.sh: --herdr-lab uses its quoted Firstmate-owned helper path"
}

test_herdr_lab_omission_is_loud_for_ship_and_scout() {
  local home id brief
  home="$TMP_ROOT/herdr-gate-home"
  mkdir -p "$home/data"
  for kind in ship scout; do
    id="brief-herdr-gate-$kind"
    if [ "$kind" = scout ]; then
      FM_HOME="$home" "$ROOT/bin/fm-brief.sh" "$id" firstmate --scout >/dev/null 2>&1
    else
      FM_HOME="$home" "$ROOT/bin/fm-brief.sh" "$id" firstmate >/dev/null 2>&1
    fi
    brief="$home/data/$id/brief.md"
    assert_grep "# Herdr lifecycle declaration - NOT ENABLED" "$brief" \
      "$kind brief silently omitted the Herdr declaration"
    assert_grep "regenerate the brief with \`--herdr-lab\` before dispatch" "$brief" \
      "$kind brief missing the fail-visible regeneration instruction"
  done
  pass "fm-brief.sh: ship and scout scaffolds make omitted Herdr intent fail-visible"
}

test_secondmate_no_projects_charter() {
  local home brief status
  home="$TMP_ROOT/no-projects-home"
  mkdir -p "$home/data"

  # The deliberate --no-projects signal scaffolds a valid project-less charter for
  # a domain whose subject is the firstmate repo itself (no clones needed).
  FM_HOME="$home" FM_SECONDMATE_CHARTER='firstmate self-development' \
    FM_SECONDMATE_SCOPE='firstmate repo work' \
    "$ROOT/bin/fm-brief.sh" fdev --secondmate --no-projects >/dev/null 2>&1; status=$?
  expect_code 0 "$status" "--no-projects secondmate brief should exit 0"
  brief="$home/data/fdev/brief.md"
  assert_present "$brief" "project-less charter was not scaffolded"
  assert_grep "# Project clones" "$brief" "project-less charter dropped the Project clones heading"
  assert_grep "None. This is a project-less domain" "$brief" \
    "project-less charter did not render a sensible no-clones note"
  assert_grep "its crews take pooled worktrees of that repo" "$brief" \
    "project-less charter operating model lost the pooled-worktree note"
  assert_no_grep "The projects above are local clones" "$brief" \
    "project-less charter kept the with-projects operating-model line"
  if grep -nE '^-[[:space:]]*$' "$brief" >/dev/null; then
    fail "project-less charter left a stray empty project bullet"
  fi

  # Accidental omission (no projects, no signal) still fails loudly, writing nothing.
  FM_HOME="$home" FM_SECONDMATE_CHARTER='x' "$ROOT/bin/fm-brief.sh" oops --secondmate >/dev/null 2>&1; status=$?
  expect_code 1 "$status" "secondmate brief with no projects and no --no-projects must fail"
  assert_absent "$home/data/oops/brief.md" "loud-failure secondmate brief still wrote a file"

  # --no-projects is mutually exclusive with a project list.
  FM_HOME="$home" FM_SECONDMATE_CHARTER='x' "$ROOT/bin/fm-brief.sh" oops2 --secondmate --no-projects alpha >/dev/null 2>&1; status=$?
  expect_code 1 "$status" "--no-projects combined with a project list must fail"

  # --no-projects applies only to secondmate charters, never a ship/scout brief.
  FM_HOME="$home" "$ROOT/bin/fm-brief.sh" oops3 somerepo --no-projects >/dev/null 2>&1; status=$?
  expect_code 1 "$status" "--no-projects on a ship brief must fail"

  pass "fm-brief.sh: --no-projects scaffolds a project-less charter and guards misuse"
}

test_herdr_lab_contract_applies_to_scouts_but_not_secondmates() {
  local home brief status=0
  home="$TMP_ROOT/herdr-kind-home"
  mkdir -p "$home/data"
  FM_HOME="$home" "$ROOT/bin/fm-brief.sh" herdr-scout firstmate --scout --herdr-lab >/dev/null 2>&1
  brief="$home/data/herdr-scout/brief.md"
  assert_grep "# Herdr isolation - HARD SAFETY CONTRACT" "$brief" \
    "scout --herdr-lab brief missing the contract"

  FM_HOME="$home" FM_SECONDMATE_CHARTER=ops "$ROOT/bin/fm-brief.sh" herdr-secondmate --secondmate firstmate --herdr-lab >/dev/null 2>&1 || status=$?
  expect_code 1 "$status" "secondmate --herdr-lab must be rejected"
  assert_absent "$home/data/herdr-secondmate/brief.md" \
    "rejected secondmate --herdr-lab still wrote a brief"
  pass "fm-brief.sh: Herdr lab contract covers scouts and rejects secondmate misuse"
}

test_pause_verb_override_renders_all_brief_scaffolds() {
  local home kind id brief
  home="$TMP_ROOT/pause-verb-home"
  mkdir -p "$home/data"

  for kind in ship scout secondmate; do
    id="brief-pause-verb-$kind"
    case "$kind" in
      ship)
        FM_HOME="$home" FM_CLASSIFY_PAUSED_VERB=awaiting \
          "$ROOT/bin/fm-brief.sh" "$id" firstmate >/dev/null 2>&1
        ;;
      scout)
        FM_HOME="$home" FM_CLASSIFY_PAUSED_VERB=awaiting \
          "$ROOT/bin/fm-brief.sh" "$id" firstmate --scout >/dev/null 2>&1
        ;;
      secondmate)
        FM_HOME="$home" FM_CLASSIFY_PAUSED_VERB=awaiting \
          "$ROOT/bin/fm-brief.sh" "$id" --secondmate --no-projects >/dev/null 2>&1
        ;;
    esac
    brief="$home/data/$id/brief.md"
    assert_grep "States: working, needs-decision, blocked, awaiting, done, failed." "$brief" \
      "$kind brief did not render the configured pause verb in its states list"
    # shellcheck disable=SC2016 # Literal backticks and braces must remain unexpanded.
    assert_grep 'Use `awaiting: {why}`' "$brief" \
      "$kind brief did not instruct the configured pause status"
    # shellcheck disable=SC2016 # Literal backticks and braces must remain unexpanded.
    assert_no_grep '`paused: {why}`' "$brief" \
      "$kind brief still instructs the default paused status"
  done
  pass "fm-brief.sh: custom pause verb renders in every scaffold"
}

test_secondmate_charter_carries_tier_role() {
  local home brief
  home="$TMP_ROOT/tier-role-home"
  mkdir -p "$home/data"
  FM_HOME="$home" FM_SECONDMATE_CHARTER='ops' \
    "$ROOT/bin/fm-brief.sh" brief-tier-role --secondmate --no-projects >/dev/null 2>&1
  brief="$home/data/brief-tier-role/brief.md"
  assert_present "$brief" "tier-role charter was not scaffolded"
  assert_grep "strict three-tier hierarchy" "$brief" "charter did not state the three-tier hierarchy"
  # shellcheck disable=SC2016 # literal backtick path must remain unexpanded
  assert_grep 'sweep your own 3rd mates' "$brief" "charter did not say the secondmate sweeps its own 3rd mates"
  # shellcheck disable=SC2016 # literal backtick path must remain unexpanded
  assert_grep '`bin/fm-sweep.sh`' "$brief" "charter did not point at the sweep script"
  # shellcheck disable=SC2016 # literal backtick path must remain unexpanded
  assert_grep '`bin/fm-consult.sh secondmate' "$brief" "charter did not offer the codex consult gate"
  assert_grep "never coordinate with other secondmates" "$brief" \
    "charter did not state secondmates never coordinate with each other"
  assert_grep "harness compacts your chat context" "$brief" "charter did not note the harness's own context compaction"
  assert_no_grep "main firstmate compacts" "$brief" \
    "charter must not claim the main firstmate manages the secondmate's context"
  pass "fm-brief.sh: secondmate charter carries the three-tier role, sweep, consult, and context-durability contract"
}

test_script_parses
test_comsub_heredoc_bodies_are_apostrophe_free
test_help_includes_entire_header
test_ship_modes_generate_clean_briefs
test_no_mistakes_dod_wording
test_peer_coordination_paragraph
test_ship_project_memory_wording
test_herdr_lab_contract_is_explicit_and_complete
test_herdr_lab_contract_quotes_foreign_firstmate_path
test_herdr_lab_omission_is_loud_for_ship_and_scout
test_herdr_lab_contract_applies_to_scouts_but_not_secondmates
test_secondmate_no_projects_charter
test_pause_verb_override_renders_all_brief_scaffolds
test_secondmate_charter_carries_tier_role
