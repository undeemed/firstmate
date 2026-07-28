#!/usr/bin/env bash
# Resolve one already-matched crew-dispatch rule or default to a concrete profile.
# Usage:
#   fm-dispatch-select.sh [--select <strategy>] [--quota-json <file>] [<rule-or-profile-json>]
#
# Input may be a full rule object with `use` and optional `select`, a single
# profile object, or a non-empty array of profile objects.
# Output is one compact JSON profile object on stdout.
# Selection diagnostics go to stderr and never alter the profile JSON.
#
# This header is the single owner of quota-aware selection mechanics:
#   - A profile object resolves to itself for backward compatibility.
#   - Every profile array is quota-aware, whether or not it carries the legacy
#     explicit `select: "quota-balanced"` strategy.
#   - It runs the installed quota-axi --json (or the --quota-json fixture).
#   - Candidates map to the quota provider and product their model consumes:
#     direct Claude -> Claude, direct Codex -> Codex, direct Grok -> Grok Build,
#     direct Kimi -> Kimi with its kimi-code/ namespace stripped, and
#     Pi/pi-signed/OpenCode models prefixed anthropic/, openai-codex/, or
#     xai/ -> Claude, Codex, or the xAI API product respectively.
#   - A candidate's score is the minimum percentRemaining among its relevant
#     general and matching model windows, or its exact Grok product window.
#     Grok's aggregate credits window is used only when product windows are not
#     exposed, so Grok Build and xAI API remain distinct.
#   - Kimi is scored on its five_hour and weekly windows plus every limit:N
#     bucket quota-axi emits, even though those buckets carry kind "unknown".
#     Inclusion is the safe direction because a score is the minimum across
#     relevant windows, so a real-but-unidentified bucket can only make a
#     candidate look more constrained, never more available. Excluding them
#     would let a Kimi whose binding constraint sits in a limit bucket score on
#     weekly alone and win against a more available harness. Narrow this to the
#     coding-capacity buckets if quota-axi later gives them a real kind.
#   - Unscorable candidates never beat candidates with usable quota data.
#   - Quota data is untrusted, so every field read from it is type-guarded, not
#     merely defaulted for absence: a wrongly-typed provider, window, id, label,
#     or state is ignored field by field. A jq string operation applied to a
#     defaulted-but-untyped value raises and aborts the whole scoring program,
#     which would throw away every other candidate's good numbers and silently
#     degrade the entire array to a random pick, so scoring narrows to the
#     affected candidate instead.
#   - Ignoring a field must make its predicate false, never vacuously true. A
#     guard that maps bad input to "" is inert only on the haystack side of a
#     match, because jq's contains("") and startswith("") are always true, so a
#     window whose id and label are wrongly typed or absent would stop being
#     ignored and become a wildcard matching every candidate. Every substring
#     test whose needle can clean to empty goes through nonempty_contains, which
#     refuses an empty needle or haystack. Emptiness is judged after cleaning,
#     not on the raw field, so a model like "-" that cleans away is unmatchable
#     rather than universal.
#   - Stale-but-cached numbers remain usable, but a fresh candidate wins unless
#     the best stale score is at least the stale-clear margin higher (default
#     20 points). Equal winning scores use a random tie-break.
#   - If quota-axi is unavailable, fails, returns unusable data, or no candidate
#     can be scored, selection falls back uniformly across every valid candidate
#     using rejection sampling over a 32-bit value from /dev/urandom. A single
#     candidate, whether the only profile in the array or the only top scorer, is
#     already the outcome and consults no random source at all, so neither an
#     unreadable source nor an absent od reader can turn a determined selection
#     into a dispatch failure. Both are probed where randomness is actually
#     consumed, so the tool gate and the source gate cannot disagree. The loud
#     refusal is reserved for a genuine choice among two or more tied candidates.
#   - Runtime quota trouble never turns malformed profile JSON into a fallback;
#     invalid input exits 2 with an actionable validation error. Profile fields
#     are typed by that validation pass, never by the scoring program's guards,
#     so a wrongly-typed harness, model, or effort stays a loud refusal.
#   - The stale-clear margin is operator config, not quota data, so a
#     non-numeric override exits 2 naming the bad value instead of reaching the
#     scoring program, whose failure would otherwise be reported as unusable
#     quota data and silently drop the whole fleet to random selection. Like the
#     od and random-source gates, it is checked at the site that reads it, right
#     before the scoring program: a determined single-profile selection and a
#     quota-unavailable uniform-random fallback never consult the margin, so a
#     typo'd override cannot turn either into a dispatch failure.
#
# FM_DISPATCH_QUOTA_AXI overrides the quota command.
# FM_DISPATCH_STALE_CLEAR_MARGIN overrides the default 20 point stale margin and
# must be a number.
# FM_DISPATCH_RANDOM_SOURCE overrides /dev/urandom for deterministic tests only.
set -u

STALE_CLEAR_MARGIN=${FM_DISPATCH_STALE_CLEAR_MARGIN:-20}
SELECT_OVERRIDE=
QUOTA_JSON_FILE=
ARGS=()

usage() {
  awk '
    NR == 1 { next }
    /^#/ { sub(/^# ?/, ""); print; next }
    { exit }
  ' "$0" >&2
}

log() {
  printf 'fm-dispatch-select: %s\n' "$*" >&2
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --select)
      [ "$#" -gt 1 ] || { echo "error: --select requires a value" >&2; exit 2; }
      SELECT_OVERRIDE=$2
      shift 2
      ;;
    --select=*)
      SELECT_OVERRIDE=${1#--select=}
      shift
      ;;
    --quota-json)
      [ "$#" -gt 1 ] || { echo "error: --quota-json requires a file" >&2; exit 2; }
      QUOTA_JSON_FILE=$2
      shift 2
      ;;
    --quota-json=*)
      QUOTA_JSON_FILE=${1#--quota-json=}
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    --)
      shift
      while [ "$#" -gt 0 ]; do
        ARGS+=("$1")
        shift
      done
      ;;
    -*)
      echo "error: unknown option $1" >&2
      exit 2
      ;;
    *)
      ARGS+=("$1")
      shift
      ;;
  esac
done

[ "${#ARGS[@]}" -le 1 ] || { echo "error: expected at most one JSON argument" >&2; exit 2; }
command -v jq >/dev/null 2>&1 || { echo "error: jq is required" >&2; exit 2; }

if [ "${#ARGS[@]}" -eq 1 ]; then
  SPEC_JSON=${ARGS[0]}
else
  SPEC_JSON=$(cat)
fi

profiles_json=$(printf '%s\n' "$SPEC_JSON" | jq -ec '
  (if type == "object" and has("use") then .use else . end)
  | if type == "array" then .
    elif type == "object" then [.]
    else error("dispatch input must be a rule, profile, or profile array")
    end
' 2>/dev/null) || { echo "error: dispatch input must be a rule, profile, or profile array" >&2; exit 2; }

validation_error=$(printf '%s\n' "$profiles_json" | jq -r '
  def verified($h): ["claude", "codex", "opencode", "pi", "pi-signed", "grok", "kimi"] | index($h);
  def effort_ok($h; $e):
    if $h == "claude" then ["low", "medium", "high", "xhigh", "max"] | index($e)
    elif $h == "codex" then ["low", "medium", "high", "xhigh"] | index($e)
    elif $h == "grok" then ["low", "medium", "high"] | index($e)
    elif $h == "pi" or $h == "pi-signed" then ["low", "medium", "high", "xhigh", "max"] | index($e)
    elif $h == "opencode" or $h == "kimi" then false
    else false
    end;
  if length == 0 then "dispatch profile array must not be empty"
  elif any(.[]; type != "object") then "each dispatch profile must be an object"
  elif any(.[]; ((.harness? | type) != "string") or (.harness | length) == 0) then "each dispatch profile needs a non-empty harness"
  elif any(.[]; has("model") and (((.model | type) != "string") or (.model | length) == 0)) then "dispatch profile model must be a non-empty string when present"
  elif any(.[]; has("effort") and (((.effort | type) != "string") or (.effort | length) == 0)) then "dispatch profile effort must be a non-empty string when present"
  elif any(.[]; .harness as $h | verified($h) | not) then "dispatch profile contains an unverified harness"
  elif any(.[]; has("effort") and (. as $profile | effort_ok($profile.harness; $profile.effort) | not)) then "dispatch profile contains an unsupported harness/effort pair"
  else empty
  end
')
[ -z "$validation_error" ] || { echo "error: $validation_error" >&2; exit 2; }

clean_profile_at() {
  local index=$1
  printf '%s\n' "$profiles_json" | jq -c --argjson index "$index" '
    def clean($p):
      {harness: $p.harness}
      + (if ($p.model? | type) == "string" then {model: $p.model} else {} end)
      + (if ($p.effort? | type) == "string" then {effort: $p.effort} else {} end);
    clean(.[$index])
  '
}

# Sole owner of every diagnostic for a failed draw, so no caller can add a
# second cause line that contradicts the real one (a missing od is not an
# unreadable source, and the remedies differ).
random_index() {
  local count=$1 source raw ceiling attempts
  source=${FM_DISPATCH_RANDOM_SOURCE:-/dev/urandom}
  [ "$count" -gt 0 ] || {
    echo "error: no dispatch candidate to choose from" >&2
    return 1
  }
  # One candidate is already the outcome, so neither the random source nor its
  # reader is consulted and an absent one cannot block a determined selection.
  [ "$count" -gt 1 ] || { printf '%s\n' 0; return 0; }
  command -v od >/dev/null 2>&1 || {
    echo "error: od is required to choose among tied dispatch candidates" >&2
    return 1
  }
  [ -r "$source" ] || {
    echo "error: OS-backed random source is unavailable: $source" >&2
    return 1
  }
  ceiling=$((4294967296 - (4294967296 % count)))
  attempts=0
  while [ "$attempts" -lt 32 ]; do
    raw=$(LC_ALL=C od -An -N4 -tu4 "$source" 2>/dev/null | tr -d '[:space:]')
    case "$raw" in
      ''|*[!0-9]*) attempts=$((attempts + 1)); continue ;;
    esac
    if [ "$raw" -lt "$ceiling" ]; then
      printf '%s\n' "$((raw % count))"
      return 0
    fi
    attempts=$((attempts + 1))
  done
  echo "error: OS-backed random source is unavailable: $source yielded no usable value" >&2
  return 1
}

random_profile() {
  local reason count index
  reason=$1
  count=$(printf '%s\n' "$profiles_json" | jq 'length')
  index=$(random_index "$count") || exit 1
  log "$reason"
  log "selection basis: random fallback"
  clean_profile_at "$index"
}

select_strategy=$SELECT_OVERRIDE
if [ -z "$select_strategy" ]; then
  select_strategy=$(printf '%s\n' "$SPEC_JSON" | jq -r '
    if type == "object" and has("use") and (.select? | type) == "string" then .select else "" end
  ' 2>/dev/null || true)
fi
if [ -n "$select_strategy" ] && [ "$select_strategy" != quota-balanced ]; then
  echo "error: unknown select strategy '$select_strategy'" >&2
  exit 2
fi

is_array=$(printf '%s\n' "$SPEC_JSON" | jq -r '
  if type == "object" and has("use") then (.use | type) == "array" else type == "array" end
')
if [ "$is_array" != true ] && [ -z "$select_strategy" ]; then
  log "selection basis: single profile"
  clean_profile_at 0
  exit 0
fi

if [ -n "$QUOTA_JSON_FILE" ]; then
  if ! quota_json=$(cat "$QUOTA_JSON_FILE" 2>/dev/null); then
    random_profile "cannot read quota JSON"
    exit 0
  fi
else
  quota_cmd=${FM_DISPATCH_QUOTA_AXI:-quota-axi}
  if ! command -v "$quota_cmd" >/dev/null 2>&1; then
    random_profile "quota-axi missing"
    exit 0
  fi
  quota_json=$("$quota_cmd" --json 2>/dev/null)
  quota_status=$?
  if [ "$quota_status" -ne 0 ]; then
    random_profile "quota-axi exited $quota_status"
    exit 0
  fi
fi

if ! printf '%s\n' "$quota_json" | jq -e 'type == "object" and (.providers | type) == "array"' >/dev/null 2>&1; then
  random_profile "quota-axi returned unparseable JSON"
  exit 0
fi

[[ $STALE_CLEAR_MARGIN =~ ^-?[0-9]+([.][0-9]+)?$ ]] || {
  echo "error: FM_DISPATCH_STALE_CLEAR_MARGIN must be a number, got: $STALE_CLEAR_MARGIN" >&2
  exit 2
}

selection=$(printf '%s\n' "$quota_json" | jq -ec \
  --argjson profiles "$profiles_json" \
  --argjson margin "$STALE_CLEAR_MARGIN" '
  def text($value): ($value | strings) // "";
  def clean_text:
    ascii_downcase | gsub("[^a-z0-9]"; "");
  def model_name($model):
    ($model | split("/") | last) as $tail
    | if ($tail | type) != "string" then ""
      else (($tail | split(":") | first) // "")
      end;
  def route($profile):
    text($profile.harness?) as $h
    | text($profile.model?) as $model
    | (["pi", "pi-signed", "opencode"] | index($h) != null) as $prefixed
    | if $h == "claude" then {provider: "claude", model: $model}
      elif $h == "codex" then {provider: "codex", model: $model}
      elif $h == "grok" then {provider: "grok", product: "grok_build", model: $model}
      elif $h == "kimi" then {provider: "kimi", model: (model_name($model))}
      elif ($prefixed and ($model | startswith("anthropic/"))) then
        {provider: "claude", model: (model_name($model))}
      elif ($prefixed and ($model | startswith("openai-codex/"))) then
        {provider: "codex", model: (model_name($model))}
      elif ($prefixed and ($model | startswith("xai/"))) then
        {provider: "grok", product: "api", model: (model_name($model))}
      else null
      end;
  def provider_for($id): [.providers[]? | objects | select(.provider == $id)][0];
  def nonempty_contains($haystack; $needle):
    ($haystack | length) > 0
    and ($needle | length) > 0
    and ($haystack | contains($needle));
  def model_window_matches($window; $model):
    if (text($window.kind?) != "model") then false
    else
      (text($window.id?) + " " + text($window.label?) | clean_text) as $scope
      | ($model | clean_text) as $wanted
      | (nonempty_contains($scope; $wanted) or nonempty_contains($wanted; $scope)
        or (["fable", "opus", "haiku", "sonnet", "spark"]
          | map(. as $family
            | nonempty_contains($scope; $family) and nonempty_contains($wanted; $family))
          | any))
    end;
  def usable_percent($window):
    (($window.percentRemaining? | type) == "number")
    and ($window.percentRemaining >= 0)
    and ($window.percentRemaining <= 100);
  def general_window_matches($window; $provider):
    text($window.id?) as $id
    | if $provider == "claude" then ["five_hour", "seven_day"] | index($id) != null
      elif $provider == "codex" then ["five_hour", "weekly"] | index($id) != null
      elif $provider == "kimi" then
        (["five_hour", "weekly"] | index($id) != null)
        or ($id | startswith("limit:"))
      else false
      end;
  def relevant_windows($provider; $route):
    (($provider.windows? | arrays) // []) as $all_windows
    | ($all_windows | map(select(usable_percent(.)))) as $windows
    | if $route.provider == "grok" then
        ($windows | map(select(.id == ("product:" + $route.product)))) as $product_windows
        | if ($product_windows | length) > 0 then $product_windows
          elif ($all_windows | map(select(text(.id?) | startswith("product:"))) | length) == 0 then
            ($windows | map(select(.id == "credits")))
          else []
          end
      else
        $windows | map(select(
          general_window_matches(.; $route.provider)
          or model_window_matches(.; $route.model)
        ))
      end;
  def candidate_metric($profile; $index):
    . as $root
    | route($profile) as $route
    | if $route == null then empty
      else ($root | provider_for($route.provider)) as $provider
      | text($provider.state?.status?) as $status
      | if ($provider == null) or (["fresh", "stale"] | index($status) | not) then empty
        else relevant_windows($provider; $route) as $windows
        | if ($windows | length) == 0 then empty
          else {
            index: $index,
            score: ($windows | map(.percentRemaining) | min),
            fresh: ($status == "fresh")
          }
          end
        end
      end;
  def best_score($items): if ($items | length) == 0 then null else ($items | map(.score) | max) end;
  . as $quota_root
  | ([$profiles | to_entries[] | . as $entry
      | ($quota_root | candidate_metric($entry.value; $entry.key))]) as $candidates
  | if ($candidates | length) == 0 then {fallback: true}
    else
      ($candidates | map(select(.fresh))) as $fresh
      | ($candidates | map(select(.fresh | not))) as $stale
      | best_score($fresh) as $fresh_best
      | best_score($stale) as $stale_best
      | (if $fresh_best != null and $stale_best != null then
          if $stale_best >= ($fresh_best + $margin) then {items: $stale, score: $stale_best}
          else {items: $fresh, score: $fresh_best}
          end
        elif $fresh_best != null then {items: $fresh, score: $fresh_best}
        else {items: $stale, score: $stale_best}
        end) as $winning
      | {fallback: false, indices: [$winning.items[] | select(.score == $winning.score) | .index]}
    end
' 2>/dev/null) || {
  random_profile "quota-axi data could not be evaluated"
  exit 0
}

if [ "$(printf '%s\n' "$selection" | jq -r '.fallback')" = true ]; then
  random_profile "no usable quota windows for candidates"
  exit 0
fi

winner_indices=$(printf '%s\n' "$selection" | jq -c '.indices')
winner_count=$(printf '%s\n' "$winner_indices" | jq 'length')
winner_offset=$(random_index "$winner_count") || exit 1
winner_index=$(printf '%s\n' "$winner_indices" | jq -r --argjson offset "$winner_offset" '.[$offset]')
log "selection basis: quota-selected"
clean_profile_at "$winner_index"
