#!/usr/bin/env bash
# Behavior tests for quota-aware crew-dispatch profile selection.
#
# End-user reproduction before the fix:
# - Initiating input: a non-empty profile array in rule use or top-level default.
# - Expected: startup accepts both locations and dispatch consults quota-axi.
# - Observed: startup rejected a default array, while a rule array without
#   select silently chose its first element without calling quota-axi.
# - Masking condition: a single profile object worked, and an explicit
#   quota-balanced rule array took the quota path.
# - Visible symptom: an actionable-looking startup invalid-config line for a
#   valid default array, or first-profile dispatch despite better usable quota.
# - Earliest divergence: bootstrap restricted default to object while use had an
#   array normalizer; selector gated quota lookup on explicit select rather than
#   the already-normalized input being an array.
# - History: 7a42707 added rule arrays and explicit quota-balanced selection;
#   8cd90fe moved the contract owner without changing that asymmetric behavior.
# - Smallest counterfactual: adding select changed a rule array to quota-aware
#   selection but could not make the same array valid under default.
# - Disconfirming evidence: object defaults, object rule uses, and explicit
#   quota-balanced rule arrays all followed their proven paths successfully.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

BASE_PATH=${FM_TEST_BASE_PATH:-/usr/bin:/bin:/usr/sbin:/sbin}
TMP_ROOT=$(fm_test_tmproot fm-dispatch-select-tests)
mkdir -p "$TMP_ROOT"
RANDOM_ZERO="$TMP_ROOT/random-zero"
RANDOM_ONE="$TMP_ROOT/random-one"
printf '\000\000\000\000' > "$RANDOM_ZERO"
printf '\001\001\001\001' > "$RANDOM_ONE"

# The restricted-PATH cases below simulate quota-axi's absence, never jq's.
# jq may live outside the minimal base path (e.g. /usr/local/bin), so expose
# exactly jq through a dedicated dir instead of appending its whole directory,
# which could leak a host quota-axi back into the "missing" case.
jq_real=$(command -v jq) || fail "jq is required by fm-dispatch-select.sh"
mkdir -p "$TMP_ROOT/jq-only"
ln -s "$jq_real" "$TMP_ROOT/jq-only/jq"
BASE_PATH="$BASE_PATH:$TMP_ROOT/jq-only"

write_quota() {
  local file=$1 claude_status=$2 claude_five=$3 claude_week=$4 codex_status=$5 codex_five=$6 codex_week=$7
  mkdir -p "$(dirname "$file")"
  cat > "$file" <<JSON
{
  "schemaVersion": 2,
  "providers": [
    {
      "provider": "claude",
      "state": { "status": "$claude_status" },
      "windows": [
        { "id": "five_hour", "kind": "session", "percentRemaining": $claude_five },
        { "id": "seven_day", "kind": "weekly", "percentRemaining": $claude_week },
        { "id": "model:fable", "label": "Fable week", "kind": "model", "percentRemaining": 100 }
      ]
    },
    {
      "provider": "codex",
      "state": { "status": "$codex_status" },
      "windows": [
        { "id": "five_hour", "kind": "session", "percentRemaining": $codex_five },
        { "id": "weekly", "kind": "weekly", "percentRemaining": $codex_week },
        { "id": "model:codex_bengalfox:5h", "label": "GPT-5.3-Codex-Spark session", "kind": "model", "percentRemaining": 100 }
      ]
    }
  ]
}
JSON
}

profiles='[{"harness":"claude","model":"claude-sonnet-5","effort":"high"},{"harness":"codex","model":"gpt-5.5","effort":"high"}]'

assert_profile() {
  local actual=$1 expected=$2 message=$3
  [ "$actual" = "$expected" ] || fail "$message, got: $actual"
}

test_implicit_array_picks_higher_min_provider() {
  local quota out err
  quota="$TMP_ROOT/higher.json"
  write_quota "$quota" fresh 80 30 fresh 70 60
  out=$(FM_DISPATCH_RANDOM_SOURCE="$RANDOM_ZERO" "$ROOT/bin/fm-dispatch-select.sh" --quota-json "$quota" "$profiles" 2>"$TMP_ROOT/higher.err")
  err=$(cat "$TMP_ROOT/higher.err")
  assert_profile "$out" '{"harness":"codex","model":"gpt-5.5","effort":"high"}' "higher-min provider should win"
  assert_contains "$err" "selection basis: quota-selected" "quota selection basis was not exposed"
  pass "every profile array implicitly picks the least constrained scorable provider"
}

test_rule_array_without_select_invokes_quota_axi() {
  local fakebin marker out rule
  fakebin=$(fm_fakebin "$TMP_ROOT/implicit-command")
  marker="$TMP_ROOT/implicit-command/called"
  cat > "$fakebin/quota-axi" <<SH
#!/usr/bin/env bash
printf '%s\n' "\$*" > '$marker'
cat <<'JSON'
{"schemaVersion":2,"providers":[{"provider":"claude","state":{"status":"fresh"},"windows":[{"id":"five_hour","kind":"session","percentRemaining":10}]},{"provider":"codex","state":{"status":"fresh"},"windows":[{"id":"five_hour","kind":"session","percentRemaining":90}]}]}
JSON
SH
  chmod +x "$fakebin/quota-axi"
  rule='{"when":"big work","use":[{"harness":"claude"},{"harness":"codex"}]}'
  out=$(PATH="$fakebin:$BASE_PATH" FM_DISPATCH_RANDOM_SOURCE="$RANDOM_ZERO" "$ROOT/bin/fm-dispatch-select.sh" "$rule" 2>/dev/null)
  assert_profile "$out" '{"harness":"codex"}' "implicit rule array should use quota data"
  assert_contains "$(cat "$marker")" "--json" "implicit array did not invoke quota-axi --json"
  pass "rule arrays need no select property to invoke installed quota-axi"
}

test_legacy_explicit_selector_stays_compatible() {
  local quota out
  quota="$TMP_ROOT/legacy.json"
  write_quota "$quota" fresh 90 80 fresh 70 60
  out=$(FM_DISPATCH_RANDOM_SOURCE="$RANDOM_ZERO" "$ROOT/bin/fm-dispatch-select.sh" --select quota-balanced --quota-json "$quota" "$profiles" 2>/dev/null)
  assert_profile "$out" '{"harness":"claude","model":"claude-sonnet-5","effort":"high"}' "legacy explicit selector changed behavior"

  out=$(FM_DISPATCH_RANDOM_SOURCE="$RANDOM_ZERO" "$ROOT/bin/fm-dispatch-select.sh" --quota-json "$quota" \
    '{"when":"big work","use":[{"harness":"claude"},{"harness":"codex"}],"select":"quota-balanced"}' 2>/dev/null)
  assert_profile "$out" '{"harness":"claude"}' "legacy rule selector changed behavior"
  pass "legacy select quota-balanced forms remain compatible"
}

test_equal_winners_use_os_random_tie_break() {
  local quota first second
  quota="$TMP_ROOT/tie.json"
  write_quota "$quota" fresh 90 50 fresh 60 50
  first=$(FM_DISPATCH_RANDOM_SOURCE="$RANDOM_ZERO" "$ROOT/bin/fm-dispatch-select.sh" --quota-json "$quota" "$profiles" 2>/dev/null)
  second=$(FM_DISPATCH_RANDOM_SOURCE="$RANDOM_ONE" "$ROOT/bin/fm-dispatch-select.sh" --quota-json "$quota" "$profiles" 2>/dev/null)
  assert_profile "$first" '{"harness":"claude","model":"claude-sonnet-5","effort":"high"}' "zero random fixture should choose first tie winner"
  assert_profile "$second" '{"harness":"codex","model":"gpt-5.5","effort":"high"}' "nonzero random fixture should choose second tie winner"
  pass "equal quota winners use the OS-backed random tie-break"
}

test_provider_and_product_mapping_through_wrappers() {
  local quota out
  quota="$TMP_ROOT/routes.json"
  cat > "$quota" <<'JSON'
{
  "schemaVersion": 2,
  "providers": [
    {"provider":"claude","state":{"status":"fresh"},"windows":[{"id":"five_hour","kind":"session","percentRemaining":45},{"id":"seven_day","kind":"weekly","percentRemaining":40}]},
    {"provider":"codex","state":{"status":"fresh"},"windows":[{"id":"five_hour","kind":"session","percentRemaining":55},{"id":"weekly","kind":"weekly","percentRemaining":50}]},
    {"provider":"grok","state":{"status":"fresh"},"windows":[
      {"id":"credits","kind":"credits","percentRemaining":1},
      {"id":"product:api","kind":"credits","percentRemaining":75},
      {"id":"product:grok_build","kind":"credits","percentRemaining":25}
    ]},
    {"provider":"kimi","state":{"status":"fresh"},"windows":[
      {"id":"five_hour","kind":"session","percentRemaining":65},
      {"id":"weekly","kind":"weekly","percentRemaining":60},
      {"id":"limit:1","label":"limit 1","kind":"unknown","percentRemaining":2}
    ]}
  ]
}
JSON
  out=$(FM_DISPATCH_RANDOM_SOURCE="$RANDOM_ZERO" "$ROOT/bin/fm-dispatch-select.sh" --quota-json "$quota" \
    '[{"harness":"claude"},{"harness":"pi","model":"openai-codex/gpt-5.5"}]' 2>/dev/null)
  assert_profile "$out" '{"harness":"pi","model":"openai-codex/gpt-5.5"}' "Pi OpenAI Codex route was not scored as Codex"

  out=$(FM_DISPATCH_RANDOM_SOURCE="$RANDOM_ZERO" "$ROOT/bin/fm-dispatch-select.sh" --quota-json "$quota" \
    '[{"harness":"pi","model":"anthropic/claude-sonnet-5"},{"harness":"codex"}]' 2>/dev/null)
  assert_profile "$out" '{"harness":"codex"}' "Pi Anthropic route was not scored as Claude"

  out=$(FM_DISPATCH_RANDOM_SOURCE="$RANDOM_ZERO" "$ROOT/bin/fm-dispatch-select.sh" --quota-json "$quota" \
    '[{"harness":"pi","model":"xai/grok-4.5"},{"harness":"grok","model":"grok-4.5"}]' 2>/dev/null)
  assert_profile "$out" '{"harness":"pi","model":"xai/grok-4.5"}' "Pi xAI API should use product:api rather than Grok Build or aggregate credits"

  out=$(FM_DISPATCH_RANDOM_SOURCE="$RANDOM_ZERO" "$ROOT/bin/fm-dispatch-select.sh" --quota-json "$quota" \
    '[{"harness":"grok"},{"harness":"claude"}]' 2>/dev/null)
  assert_profile "$out" '{"harness":"claude"}' "direct Grok should use product:grok_build"

  out=$(FM_DISPATCH_RANDOM_SOURCE="$RANDOM_ZERO" "$ROOT/bin/fm-dispatch-select.sh" --quota-json "$quota" \
    '[{"harness":"opencode","model":"unmapped/model"},{"harness":"kimi","model":"kimi-code/k3"}]' 2>/dev/null)
  assert_profile "$out" '{"harness":"kimi","model":"kimi-code/k3"}' "direct Kimi was not scored against the Kimi provider at all"

  out=$(FM_DISPATCH_RANDOM_SOURCE="$RANDOM_ZERO" "$ROOT/bin/fm-dispatch-select.sh" --quota-json "$quota" \
    '[{"harness":"claude"},{"harness":"kimi","model":"kimi-code/k3"}]' 2>/dev/null)
  assert_profile "$out" '{"harness":"claude"}' "direct Kimi must be constrained by its limit:N bucket, not scored on five_hour and weekly alone"

  out=$(FM_DISPATCH_RANDOM_SOURCE="$RANDOM_ZERO" "$ROOT/bin/fm-dispatch-select.sh" --quota-json "$quota" \
    '[{"harness":"pi-signed","model":"anthropic/claude-sonnet-5"},{"harness":"grok"}]' 2>/dev/null)
  assert_profile "$out" '{"harness":"pi-signed","model":"anthropic/claude-sonnet-5"}' "pi-signed Anthropic route was not scored as Claude"

  out=$(FM_DISPATCH_RANDOM_SOURCE="$RANDOM_ZERO" "$ROOT/bin/fm-dispatch-select.sh" --quota-json "$quota" \
    '[{"harness":"pi-signed","model":"xai/grok-4.5"},{"harness":"codex"}]' 2>/dev/null)
  assert_profile "$out" '{"harness":"pi-signed","model":"xai/grok-4.5"}' "pi-signed xAI route was not scored against product:api"
  pass "direct and wrapper-hosted candidates map to consumed Claude, Codex, xAI API, Grok Build, and Kimi quota"
}

test_kimi_scores_through_general_windows_without_a_model() {
  local quota out err
  quota="$TMP_ROOT/kimi-modelless.json"
  cat > "$quota" <<'JSON'
{"schemaVersion":2,"providers":[
  {"provider":"claude","state":{"status":"fresh"},"windows":[
    {"id":"five_hour","kind":"session","percentRemaining":10},
    {"id":"seven_day","kind":"weekly","percentRemaining":10}
  ]},
  {"provider":"kimi","state":{"status":"fresh"},"windows":[
    {"id":"five_hour","kind":"session","percentRemaining":90},
    {"id":"weekly","kind":"weekly","percentRemaining":95}
  ]}
]}
JSON
  out=$(FM_DISPATCH_RANDOM_SOURCE="$RANDOM_ZERO" "$ROOT/bin/fm-dispatch-select.sh" --quota-json "$quota" \
    '[{"harness":"claude"},{"harness":"kimi"}]' 2>"$TMP_ROOT/kimi-modelless.err")
  err=$(cat "$TMP_ROOT/kimi-modelless.err")
  assert_profile "$out" '{"harness":"kimi"}' "model-less Kimi candidate was not scored through its provider windows"
  assert_contains "$err" "selection basis: quota-selected" "model-less Kimi profile degraded the array to a non-quota basis"
  assert_not_contains "$err" "could not be evaluated" "model-less Kimi profile aborted quota evaluation"

  out=$(FM_DISPATCH_RANDOM_SOURCE="$RANDOM_ZERO" "$ROOT/bin/fm-dispatch-select.sh" --quota-json "$quota" \
    '[{"harness":"kimi"},{"harness":"kimi","model":"kimi-code/k3"},{"harness":"claude"}]' 2>/dev/null)
  assert_profile "$out" '{"harness":"kimi"}' "model-less and model-carrying Kimi candidates should tie on provider windows"
  pass "a Kimi profile without a model stays quota-aware instead of aborting the whole array"
}

test_kimi_limit_buckets_constrain_the_candidate() {
  local quota out err
  quota="$TMP_ROOT/kimi-limit-exhausted.json"
  cat > "$quota" <<'JSON'
{"schemaVersion":2,"providers":[
  {"provider":"claude","state":{"status":"fresh"},"windows":[
    {"id":"five_hour","kind":"session","percentRemaining":40},
    {"id":"seven_day","kind":"weekly","percentRemaining":40}
  ]},
  {"provider":"kimi","state":{"status":"fresh"},"windows":[
    {"id":"five_hour","kind":"session","percentRemaining":90},
    {"id":"weekly","kind":"weekly","percentRemaining":95},
    {"id":"limit:1","label":"limit 1","kind":"unknown","percentRemaining":0}
  ]}
]}
JSON
  out=$(FM_DISPATCH_RANDOM_SOURCE="$RANDOM_ZERO" "$ROOT/bin/fm-dispatch-select.sh" --quota-json "$quota" \
    '[{"harness":"claude"},{"harness":"kimi","model":"kimi-code/k3"}]' 2>"$TMP_ROOT/kimi-limit.err")
  err=$(cat "$TMP_ROOT/kimi-limit.err")
  assert_profile "$out" '{"harness":"claude"}' "an exhausted Kimi limit bucket must lose to a middling candidate instead of winning on weekly"
  assert_contains "$err" "selection basis: quota-selected" "Kimi limit-bucket scoring degraded the array to a non-quota basis"

  quota="$TMP_ROOT/kimi-limit-available.json"
  cat > "$quota" <<'JSON'
{"schemaVersion":2,"providers":[
  {"provider":"claude","state":{"status":"fresh"},"windows":[
    {"id":"five_hour","kind":"session","percentRemaining":40},
    {"id":"seven_day","kind":"weekly","percentRemaining":40}
  ]},
  {"provider":"kimi","state":{"status":"fresh"},"windows":[
    {"id":"five_hour","kind":"session","percentRemaining":90},
    {"id":"weekly","kind":"weekly","percentRemaining":95},
    {"id":"limit:1","label":"limit 1","kind":"unknown","percentRemaining":97},
    {"id":"limit:2","label":"limit 2","kind":"unknown"}
  ]}
]}
JSON
  out=$(FM_DISPATCH_RANDOM_SOURCE="$RANDOM_ZERO" "$ROOT/bin/fm-dispatch-select.sh" --quota-json "$quota" \
    '[{"harness":"claude"},{"harness":"kimi","model":"kimi-code/k3"}]' 2>/dev/null)
  assert_profile "$out" '{"harness":"kimi","model":"kimi-code/k3"}' "an available Kimi limit bucket, and one without a usable percent, must not sink the candidate"
  pass "Kimi limit buckets count toward its score without making an otherwise available candidate unscorable"
}

# Quota data is untrusted: quota-axi may emit a wrongly-typed field, and a jq
# string operation on a merely-defaulted value raises and aborts the WHOLE
# scoring program, so one bad field would discard every other candidate's good
# numbers and silently degrade the array to a random pick. Every row keeps one
# healthy candidate that must still win through the quota path.
HEALTHY_CLAUDE='{"provider":"claude","state":{"status":"fresh"},"windows":[{"id":"five_hour","kind":"session","percentRemaining":10},{"id":"seven_day","kind":"weekly","percentRemaining":10}]}'
HEALTHY_KIMI='{"provider":"kimi","state":{"status":"fresh"},"windows":[{"id":"five_hour","kind":"session","percentRemaining":90},{"id":"weekly","kind":"weekly","percentRemaining":95}]}'
MIDDLING_KIMI='{"provider":"kimi","state":{"status":"fresh"},"windows":[{"id":"five_hour","kind":"session","percentRemaining":50},{"id":"weekly","kind":"weekly","percentRemaining":50}]}'

test_wrongly_typed_quota_fields_never_abort_scoring() {
  local name candidates providers quota out err n
  n=0
  while IFS='^' read -r name candidates providers; do
    n=$((n + 1))
    quota="$TMP_ROOT/typed-$n.json"
    printf '{"schemaVersion":2,"providers":[%s]}\n' "$providers" > "$quota"
    out=$(FM_DISPATCH_RANDOM_SOURCE="$RANDOM_ZERO" "$ROOT/bin/fm-dispatch-select.sh" \
      --quota-json "$quota" "$candidates" 2>"$TMP_ROOT/typed-$n.err")
    err=$(cat "$TMP_ROOT/typed-$n.err")
    assert_profile "$out" '{"harness":"kimi","model":"kimi-code/k3"}' "$name should leave every other candidate scorable"
    assert_contains "$err" "selection basis: quota-selected" "$name degraded the whole array to a non-quota basis"
    assert_not_contains "$err" "could not be evaluated" "$name aborted quota evaluation"
  done <<ROWS
non-string Kimi window ids^[{"harness":"claude"},{"harness":"kimi","model":"kimi-code/k3"}]^$HEALTHY_CLAUDE,{"provider":"kimi","state":{"status":"fresh"},"windows":[{"id":88,"kind":"session","percentRemaining":1},{"id":["limit:1"],"kind":"unknown","percentRemaining":1},{"id":"five_hour","kind":"session","percentRemaining":90},{"id":"weekly","kind":"weekly","percentRemaining":95}]}
non-string model window id and label^[{"harness":"claude","model":"claude-sonnet-5"},{"harness":"kimi","model":"kimi-code/k3"}]^{"provider":"claude","state":{"status":"fresh"},"windows":[{"id":"five_hour","kind":"session","percentRemaining":10},{"id":"seven_day","kind":"weekly","percentRemaining":10},{"id":7,"kind":"model","label":42,"percentRemaining":5}]},$HEALTHY_KIMI
non-object provider entry^[{"harness":"claude"},{"harness":"kimi","model":"kimi-code/k3"}]^"not-a-provider",$HEALTHY_CLAUDE,$HEALTHY_KIMI
non-array provider windows^[{"harness":"claude"},{"harness":"kimi","model":"kimi-code/k3"}]^{"provider":"claude","state":{"status":"fresh"},"windows":"none"},$HEALTHY_KIMI
non-string provider state^[{"harness":"claude"},{"harness":"kimi","model":"kimi-code/k3"}]^{"provider":"claude","state":7,"windows":[{"id":"five_hour","kind":"session","percentRemaining":100}]},$HEALTHY_KIMI
non-string and non-object Grok product windows^[{"harness":"grok"},{"harness":"kimi","model":"kimi-code/k3"}]^{"provider":"grok","state":{"status":"fresh"},"windows":[{"id":9,"kind":"credits","percentRemaining":50},"junk",{"id":"credits","kind":"credits","percentRemaining":50}]},$HEALTHY_KIMI
ROWS
  pass "wrongly-typed quota fields are ignored per field instead of aborting the whole array"
}

# Ignoring an untrusted field must make its predicate false, not vacuously
# true. jq's contains("") is always true, so a guard that maps a wrongly-typed
# or absent window id and label to "" turns that window into a wildcard
# relevant to EVERY candidate on the provider, and because a score is the
# minimum across relevant windows a single degenerate window silently drags a
# genuinely available harness to the bottom. The abort-safety rows above cannot
# see this: they keep the degenerate provider as the loser either way. Each row
# here needs the healthy candidate to be the one carrying the degenerate
# window, so only the wildcard can invert the winner.
test_ignored_model_window_fields_never_match_every_candidate() {
  local name candidates providers quota out err n
  n=0
  while IFS='^' read -r name candidates providers; do
    n=$((n + 1))
    quota="$TMP_ROOT/wildcard-$n.json"
    printf '{"schemaVersion":2,"providers":[%s]}\n' "$providers" > "$quota"
    out=$(FM_DISPATCH_RANDOM_SOURCE="$RANDOM_ZERO" "$ROOT/bin/fm-dispatch-select.sh" \
      --quota-json "$quota" "$candidates" 2>"$TMP_ROOT/wildcard-$n.err")
    err=$(cat "$TMP_ROOT/wildcard-$n.err")
    assert_contains "$out" '"harness":"claude"' "$name made an unidentified model window score the available candidate"
    assert_contains "$err" "selection basis: quota-selected" "$name degraded the whole array to a non-quota basis"
  done <<ROWS
a wrongly-typed model window id and label^[{"harness":"claude","model":"claude-sonnet-5"},{"harness":"kimi","model":"kimi-code/k3"}]^{"provider":"claude","state":{"status":"fresh"},"windows":[{"id":"five_hour","kind":"session","percentRemaining":90},{"id":"seven_day","kind":"weekly","percentRemaining":90},{"id":7,"kind":"model","label":42,"percentRemaining":5}]},$MIDDLING_KIMI
an absent model window id and label^[{"harness":"claude","model":"claude-sonnet-5"},{"harness":"kimi","model":"kimi-code/k3"}]^{"provider":"claude","state":{"status":"fresh"},"windows":[{"id":"five_hour","kind":"session","percentRemaining":90},{"id":"seven_day","kind":"weekly","percentRemaining":90},{"kind":"model","percentRemaining":5}]},$MIDDLING_KIMI
a profile model that cleans to empty^[{"harness":"claude","model":"-"},{"harness":"kimi","model":"kimi-code/k3"}]^{"provider":"claude","state":{"status":"fresh"},"windows":[{"id":"five_hour","kind":"session","percentRemaining":90},{"id":"seven_day","kind":"weekly","percentRemaining":90},{"id":"model:fable","label":"Fable week","kind":"model","percentRemaining":5}]},$MIDDLING_KIMI
ROWS
  pass "an unidentified model window or an empty-cleaning model matches nothing instead of every candidate"
}

test_newly_verified_harnesses_clear_validation() {
  local quota out status body
  quota="$TMP_ROOT/verified-harnesses.json"
  printf '%s\n' '{"schemaVersion":2,"providers":[]}' > "$quota"
  for body in \
    '[{"harness":"kimi"}]' \
    '[{"harness":"kimi","model":"kimi-code/k3"}]' \
    '[{"harness":"pi-signed","model":"anthropic/claude-sonnet-5","effort":"max"}]' \
    '[{"harness":"pi-signed","model":"xai/grok-4.5","effort":"low"}]'; do
    status=0
    out=$(FM_DISPATCH_RANDOM_SOURCE="$RANDOM_ZERO" "$ROOT/bin/fm-dispatch-select.sh" --quota-json "$quota" "$body" 2>/dev/null) || status=$?
    expect_code 0 "$status" "verified harness profile should not be a validation error: $body"
    assert_contains "$out" '"harness"' "verified harness profile did not resolve to a profile: $body"
  done
  pass "kimi and pi-signed profiles clear validation with the effort levels bootstrap accepts"
}

test_most_constrained_relevant_window_scores_candidate() {
  local quota out
  quota="$TMP_ROOT/scoped.json"
  cat > "$quota" <<'JSON'
{"schemaVersion":2,"providers":[
  {"provider":"claude","state":{"status":"fresh"},"windows":[
    {"id":"five_hour","kind":"session","percentRemaining":90},
    {"id":"seven_day","kind":"weekly","percentRemaining":80},
    {"id":"model:fable","label":"Fable week","kind":"model","percentRemaining":5}
  ]},
  {"provider":"codex","state":{"status":"fresh"},"windows":[
    {"id":"five_hour","kind":"session","percentRemaining":30},
    {"id":"weekly","kind":"weekly","percentRemaining":30},
    {"id":"code_review_five_hour","label":"code review session","kind":"session","percentRemaining":1},
    {"id":"code_review_weekly","label":"code review week","kind":"weekly","percentRemaining":1},
    {"id":"model:other:5h","label":"Unrelated preview session","kind":"model","percentRemaining":1}
  ]}
]}
JSON
  out=$(FM_DISPATCH_RANDOM_SOURCE="$RANDOM_ZERO" "$ROOT/bin/fm-dispatch-select.sh" --quota-json "$quota" \
    '[{"harness":"claude","model":"claude-fable-5"},{"harness":"codex","model":"gpt-5.5"}]' 2>/dev/null)
  assert_profile "$out" '{"harness":"codex","model":"gpt-5.5"}' "matching model window was not included or unrelated model window was included"
  pass "candidate score uses its most constrained general or matching model quota window"
}

test_grok_aggregate_fallback_requires_no_product_windows() {
  local quota out
  quota="$TMP_ROOT/grok-partial-products.json"
  cat > "$quota" <<'JSON'
{"schemaVersion":2,"providers":[
  {"provider":"grok","state":{"status":"fresh"},"windows":[
    {"id":"credits","kind":"credits","percentRemaining":100},
    {"id":"product:grok_build","kind":"credits","percentRemaining":90}
  ]},
  {"provider":"claude","state":{"status":"fresh"},"windows":[
    {"id":"five_hour","kind":"session","percentRemaining":5},
    {"id":"seven_day","kind":"weekly","percentRemaining":5}
  ]}
]}
JSON
  out=$(FM_DISPATCH_RANDOM_SOURCE="$RANDOM_ZERO" "$ROOT/bin/fm-dispatch-select.sh" --quota-json "$quota" \
    '[{"harness":"pi","model":"xai/grok-4.5"},{"harness":"claude"}]' 2>/dev/null)
  assert_profile "$out" '{"harness":"claude"}' "xAI API route used aggregate credits despite exposed product windows"
  pass "Grok aggregate credits are used only when product windows are absent"
}

test_stale_cache_needs_clear_margin_to_beat_fresh() {
  local quota out
  quota="$TMP_ROOT/stale-margin.json"
  write_quota "$quota" stale 85 70 fresh 65 60
  out=$(FM_DISPATCH_RANDOM_SOURCE="$RANDOM_ZERO" "$ROOT/bin/fm-dispatch-select.sh" --quota-json "$quota" "$profiles" 2>/dev/null)
  assert_profile "$out" '{"harness":"codex","model":"gpt-5.5","effort":"high"}' "fresh provider should win below stale margin"

  write_quota "$quota" stale 90 85 fresh 65 60
  out=$(FM_DISPATCH_RANDOM_SOURCE="$RANDOM_ZERO" "$ROOT/bin/fm-dispatch-select.sh" --quota-json "$quota" "$profiles" 2>/dev/null)
  assert_profile "$out" '{"harness":"claude","model":"claude-sonnet-5","effort":"high"}' "stale provider should win after clearing margin"
  pass "stale cached quota retains the documented freshness margin"
}

test_partial_quota_data_prefers_scorable_candidate() {
  local quota out
  quota="$TMP_ROOT/partial.json"
  cat > "$quota" <<'JSON'
{"schemaVersion":2,"providers":[{"provider":"codex","state":{"status":"fresh"},"windows":[{"id":"five_hour","kind":"session","percentRemaining":4}]}]}
JSON
  out=$(FM_DISPATCH_RANDOM_SOURCE="$RANDOM_ZERO" "$ROOT/bin/fm-dispatch-select.sh" --quota-json "$quota" "$profiles" 2>/dev/null)
  assert_profile "$out" '{"harness":"codex","model":"gpt-5.5","effort":"high"}' "unscorable first candidate beat usable Codex data"
  pass "partial quota data picks the best scorable candidate instead of an unscorable candidate"
}

assert_random_fallback_chooses_second() {
  local out_file=$1 err_file=$2
  shift 2
  FM_DISPATCH_RANDOM_SOURCE="$RANDOM_ONE" "$@" >"$out_file" 2>"$err_file"
  assert_profile "$(cat "$out_file")" '{"harness":"codex","model":"gpt-5.5","effort":"high"}' "random fallback fixture should choose the second candidate"
  assert_contains "$(cat "$err_file")" "selection basis: random fallback" "random fallback basis was not exposed"
}

test_operational_quota_failures_use_uniform_random_fallback() {
  local fakebin quota
  fakebin=$(fm_fakebin "$TMP_ROOT/missing")
  assert_random_fallback_chooses_second "$TMP_ROOT/missing.out" "$TMP_ROOT/missing.err" \
    env PATH="$fakebin:$BASE_PATH" "$ROOT/bin/fm-dispatch-select.sh" "$profiles"
  assert_contains "$(cat "$TMP_ROOT/missing.err")" "quota-axi missing" "missing quota-axi reason was not logged"

  fakebin=$(fm_fakebin "$TMP_ROOT/error")
  cat > "$fakebin/quota-axi" <<'SH'
#!/usr/bin/env bash
exit 42
SH
  chmod +x "$fakebin/quota-axi"
  assert_random_fallback_chooses_second "$TMP_ROOT/error.out" "$TMP_ROOT/error.err" \
    env PATH="$fakebin:$BASE_PATH" "$ROOT/bin/fm-dispatch-select.sh" "$profiles"
  assert_contains "$(cat "$TMP_ROOT/error.err")" "quota-axi exited 42" "quota-axi error reason was not logged"

  quota="$TMP_ROOT/bad.json"
  printf '%s\n' not-json > "$quota"
  assert_random_fallback_chooses_second "$TMP_ROOT/bad.out" "$TMP_ROOT/bad.err" \
    "$ROOT/bin/fm-dispatch-select.sh" --quota-json "$quota" "$profiles"
  assert_contains "$(cat "$TMP_ROOT/bad.err")" "unparseable JSON" "bad quota JSON reason was not logged"

  printf '%s\n' '{"schemaVersion":2,"providers":[]}' > "$quota"
  assert_random_fallback_chooses_second "$TMP_ROOT/empty.out" "$TMP_ROOT/empty.err" \
    "$ROOT/bin/fm-dispatch-select.sh" --quota-json "$quota" "$profiles"
  assert_contains "$(cat "$TMP_ROOT/empty.err")" "no usable quota windows" "wholly unusable quota reason was not logged"
  pass "missing, failed, malformed, and wholly unusable quota data use OS-backed random fallback"
}

test_single_profile_and_one_element_array() {
  local fakebin marker out err
  fakebin=$(fm_fakebin "$TMP_ROOT/single")
  marker="$TMP_ROOT/single/called"
  cat > "$fakebin/quota-axi" <<SH
#!/usr/bin/env bash
printf called > '$marker'
exit 1
SH
  chmod +x "$fakebin/quota-axi"

  out=$(PATH="$fakebin:$BASE_PATH" "$ROOT/bin/fm-dispatch-select.sh" '{"harness":"grok","model":"grok-4.5","effort":"high"}' 2>/dev/null)
  assert_profile "$out" '{"harness":"grok","model":"grok-4.5","effort":"high"}' "single profile object should resolve to itself"
  [ ! -e "$marker" ] || fail "single profile object should not invoke quota-axi"

  out=$(PATH="$fakebin:$BASE_PATH" FM_DISPATCH_RANDOM_SOURCE="$RANDOM_ONE" "$ROOT/bin/fm-dispatch-select.sh" \
    '[{"harness":"grok","model":"grok-4.5","effort":"high"}]' 2>"$TMP_ROOT/one.err")
  err=$(cat "$TMP_ROOT/one.err")
  assert_profile "$out" '{"harness":"grok","model":"grok-4.5","effort":"high"}' "one-element array should remain selectable"
  [ -e "$marker" ] || fail "one-element array should invoke quota-axi"
  assert_contains "$err" "selection basis: random fallback" "one-element operational fallback basis was not logged"
  pass "single objects remain backward compatible and one-element arrays remain quota-aware"
}

# A determined outcome needs no randomness, so an unreadable random source must
# not turn it into a dispatch failure (docs/configuration.md: quota-data trouble
# never blocks dispatch). The loud refusal stays only for a genuine tie.
test_determined_outcome_never_needs_a_random_source() {
  local fakebin quota out err status unreadable
  unreadable="$TMP_ROOT/no-such-random-source"
  rm -f "$unreadable"

  fakebin=$(fm_fakebin "$TMP_ROOT/determined")
  out=$(PATH="$fakebin:$BASE_PATH" FM_DISPATCH_RANDOM_SOURCE="$unreadable" \
    "$ROOT/bin/fm-dispatch-select.sh" '[{"harness":"grok","model":"grok-4.5","effort":"high"}]' \
    2>"$TMP_ROOT/determined-one.err") \
    || fail "one-element array failed when the random source was unreadable"
  assert_profile "$out" '{"harness":"grok","model":"grok-4.5","effort":"high"}' \
    "one-element array should resolve without consulting a random source"

  quota="$TMP_ROOT/determined.json"
  write_quota "$quota" fresh 80 70 fresh 20 15
  out=$(FM_DISPATCH_RANDOM_SOURCE="$unreadable" "$ROOT/bin/fm-dispatch-select.sh" \
    --quota-json "$quota" "$profiles" 2>"$TMP_ROOT/determined-win.err") \
    || fail "unique quota winner failed when the random source was unreadable"
  assert_profile "$out" '{"harness":"claude","model":"claude-sonnet-5","effort":"high"}' \
    "a single top scorer should resolve without consulting a random source"

  quota="$TMP_ROOT/determined-tie.json"
  write_quota "$quota" fresh 90 50 fresh 60 50
  status=0
  out=$(FM_DISPATCH_RANDOM_SOURCE="$unreadable" "$ROOT/bin/fm-dispatch-select.sh" \
    --quota-json "$quota" "$profiles" 2>"$TMP_ROOT/determined-tie.err") || status=$?
  err=$(cat "$TMP_ROOT/determined-tie.err")
  expect_code 1 "$status" "a genuine tie must still refuse loudly without a random source"
  assert_contains "$err" "OS-backed random source is unavailable" \
    "tied candidates lost the loud random-source refusal"
  [ "$err" = "error: OS-backed random source is unavailable: $unreadable" ] \
    || fail "the random-source refusal must be the only stderr line and name the source; got: $err"
  [ -z "$out" ] || fail "tied candidates emitted a profile without a usable random source: $out"
  pass "a determined selection needs no random source while a genuine tie still refuses loudly"
}

# The od reader is probed where randomness is consumed, exactly like the random
# source itself, so the tool gate and the source gate cannot disagree: a
# determined outcome must resolve with od absent, and only a genuine tie refuses.
test_determined_outcome_never_needs_od() {
  local fakebin bash_env quota out err status
  bash_env="$TMP_ROOT/no-od.bash"
  cat > "$bash_env" <<'SH'
command() {
  if [ "${1:-}" = -v ] && [ "${2:-}" = od ]; then
    return 1
  fi
  builtin command "$@"
}
SH

  fakebin=$(fm_fakebin "$TMP_ROOT/no-od")
  out=$(PATH="$fakebin:$BASE_PATH" BASH_ENV="$bash_env" \
    "$ROOT/bin/fm-dispatch-select.sh" '{"harness":"grok","model":"grok-4.5","effort":"high"}' 2>/dev/null) \
    || fail "single profile object failed when od was absent"
  assert_profile "$out" '{"harness":"grok","model":"grok-4.5","effort":"high"}' \
    "single profile object should resolve without od"

  out=$(PATH="$fakebin:$BASE_PATH" BASH_ENV="$bash_env" \
    "$ROOT/bin/fm-dispatch-select.sh" '[{"harness":"grok","model":"grok-4.5","effort":"high"}]' 2>/dev/null) \
    || fail "one-element array failed when od was absent"
  assert_profile "$out" '{"harness":"grok","model":"grok-4.5","effort":"high"}' \
    "one-element array should resolve without od"

  quota="$TMP_ROOT/no-od-winner.json"
  write_quota "$quota" fresh 80 70 fresh 20 15
  out=$(BASH_ENV="$bash_env" "$ROOT/bin/fm-dispatch-select.sh" \
    --quota-json "$quota" "$profiles" 2>/dev/null) \
    || fail "unique quota winner failed when od was absent"
  assert_profile "$out" '{"harness":"claude","model":"claude-sonnet-5","effort":"high"}' \
    "a single top scorer should resolve without od"

  quota="$TMP_ROOT/no-od-tie.json"
  write_quota "$quota" fresh 90 50 fresh 60 50
  status=0
  out=$(BASH_ENV="$bash_env" FM_DISPATCH_RANDOM_SOURCE="$RANDOM_ONE" \
    "$ROOT/bin/fm-dispatch-select.sh" --quota-json "$quota" "$profiles" \
    2>"$TMP_ROOT/no-od-tie.err") || status=$?
  err=$(cat "$TMP_ROOT/no-od-tie.err")
  expect_code 1 "$status" "a genuine tie must still refuse loudly when od is absent"
  assert_contains "$err" "od is required to choose among tied dispatch candidates" \
    "the tie refusal did not name the missing od"
  # Exact match, not a substring: the missing reader is the only cause, so a
  # second line blaming the random source would name a remedy that fixes nothing.
  [ "$err" = "error: od is required to choose among tied dispatch candidates" ] \
    || fail "the missing-od refusal must be the only stderr line; got: $err"
  assert_not_contains "$err" "OS-backed random source is unavailable" \
    "a readable random source was wrongly blamed for the missing od reader"
  [ -z "$out" ] || fail "tied candidates emitted a profile without od: $out"
  pass "a determined selection needs no od while a genuine tie names the missing od"
}

test_malformed_profile_arrays_are_validation_errors() {
  local body expect out status n
  n=0
  while IFS='^' read -r body expect; do
    n=$((n + 1))
    out=$(FM_DISPATCH_RANDOM_SOURCE="$RANDOM_ONE" "$ROOT/bin/fm-dispatch-select.sh" "$body" 2>&1)
    status=$?
    expect_code 2 "$status" "malformed profile array should exit 2"
    assert_contains "$out" "$expect" "malformed profile array did not explain validation error"
    assert_not_contains "$out" "random fallback" "malformed profile array incorrectly used operational fallback"
  done <<'ROWS'
[]^must not be empty
["claude"]^must be an object
[{"model":"claude-sonnet-5"}]^needs a non-empty harness
[{"harness":"claude","model":3}]^model must be a non-empty string
[{"harness":"claude","model":null}]^model must be a non-empty string
[{"harness":"claude","model":{"name":"claude-sonnet-5"}}]^model must be a non-empty string
[{"harness":3}]^needs a non-empty harness
[{"harness":"spaceship"}]^contains an unverified harness
[{"harness":"codex","effort":"max"}]^contains an unsupported harness/effort pair
[{"harness":"kimi","effort":"low"}]^contains an unsupported harness/effort pair
[{"harness":"pi-signed","effort":"turbo"}]^contains an unsupported harness/effort pair
ROWS
  pass "malformed arrays stay actionable validation errors and never enter random fallback"
}

test_invalid_stale_margin_is_an_operator_config_error() {
  local quota out status value
  quota="$TMP_ROOT/margin-invalid.json"
  write_quota "$quota" stale 90 85 fresh 65 60
  for value in '20%' 'high' '-' '20.' '[]' 'null' '-20'; do
    status=0
    out=$(FM_DISPATCH_STALE_CLEAR_MARGIN="$value" FM_DISPATCH_RANDOM_SOURCE="$RANDOM_ONE" \
      "$ROOT/bin/fm-dispatch-select.sh" --quota-json "$quota" "$profiles" 2>&1) || status=$?
    expect_code 2 "$status" "invalid stale margin should exit 2: $value"
    assert_contains "$out" "FM_DISPATCH_STALE_CLEAR_MARGIN must be a non-negative number" \
      "invalid stale margin did not name the operator-config cause: $value"
    assert_not_contains "$out" "quota-axi data could not be evaluated" \
      "quota data was blamed for a bad stale margin: $value"
    assert_not_contains "$out" "random fallback" \
      "bad stale margin degraded selection to random fallback: $value"
  done

  write_quota "$quota" stale 85 70 fresh 65 60
  out=$(FM_DISPATCH_STALE_CLEAR_MARGIN=0 FM_DISPATCH_RANDOM_SOURCE="$RANDOM_ZERO" \
    "$ROOT/bin/fm-dispatch-select.sh" --quota-json "$quota" "$profiles" 2>/dev/null)
  assert_profile "$out" '{"harness":"claude","model":"claude-sonnet-5","effort":"high"}' \
    "a numeric stale margin override stopped being honored"
  pass "a bad stale margin refuses as operator config while numeric margins still score"
}

# The margin gate belongs at the scoring program that reads it, so selections
# that never consult it cannot be turned into a dispatch failure by a typo.
test_bad_stale_margin_only_blocks_the_selection_that_reads_it() {
  local fakebin quota out status err
  quota="$TMP_ROOT/margin-placement.json"
  write_quota "$quota" stale 90 85 fresh 65 60

  status=0
  out=$(FM_DISPATCH_STALE_CLEAR_MARGIN='20%' \
    "$ROOT/bin/fm-dispatch-select.sh" --quota-json "$quota" "$profiles" 2>&1) || status=$?
  expect_code 2 "$status" "a scored multi-profile dispatch must still refuse a bad stale margin"
  assert_contains "$out" "FM_DISPATCH_STALE_CLEAR_MARGIN must be a non-negative number" \
    "the scored dispatch did not name the operator-config cause"

  out=$(FM_DISPATCH_STALE_CLEAR_MARGIN='20%' \
    "$ROOT/bin/fm-dispatch-select.sh" '{"harness":"grok","model":"grok-4.5","effort":"high"}' 2>/dev/null)
  assert_profile "$out" '{"harness":"grok","model":"grok-4.5","effort":"high"}' \
    "a bad stale margin blocked a single-profile selection that never reads it"

  fakebin=$(fm_fakebin "$TMP_ROOT/margin-fallback")
  out=$(PATH="$fakebin:$BASE_PATH" FM_DISPATCH_STALE_CLEAR_MARGIN='20%' \
    FM_DISPATCH_RANDOM_SOURCE="$RANDOM_ONE" \
    "$ROOT/bin/fm-dispatch-select.sh" "$profiles" 2>"$TMP_ROOT/margin-fallback.err")
  err=$(cat "$TMP_ROOT/margin-fallback.err")
  assert_profile "$out" '{"harness":"codex","model":"gpt-5.5","effort":"high"}' \
    "a bad stale margin blocked the quota-unavailable fallback that never reads it"
  assert_contains "$err" "quota-axi missing" "the quota-unavailable fallback reason was not logged"
  assert_not_contains "$err" "FM_DISPATCH_STALE_CLEAR_MARGIN" \
    "the quota-unavailable fallback reported an unread margin"
  pass "the stale margin gate fires only where the scoring program consumes it"
}

test_implicit_array_picks_higher_min_provider
test_rule_array_without_select_invokes_quota_axi
test_legacy_explicit_selector_stays_compatible
test_equal_winners_use_os_random_tie_break
test_provider_and_product_mapping_through_wrappers
test_kimi_scores_through_general_windows_without_a_model
test_kimi_limit_buckets_constrain_the_candidate
test_wrongly_typed_quota_fields_never_abort_scoring
test_ignored_model_window_fields_never_match_every_candidate
test_newly_verified_harnesses_clear_validation
test_most_constrained_relevant_window_scores_candidate
test_grok_aggregate_fallback_requires_no_product_windows
test_stale_cache_needs_clear_margin_to_beat_fresh
test_partial_quota_data_prefers_scorable_candidate
test_operational_quota_failures_use_uniform_random_fallback
test_single_profile_and_one_element_array
test_determined_outcome_never_needs_a_random_source
test_determined_outcome_never_needs_od
test_malformed_profile_arrays_are_validation_errors
test_invalid_stale_margin_is_an_operator_config_error
test_bad_stale_margin_only_blocks_the_selection_that_reads_it

echo "# all fm-dispatch-select tests passed"
