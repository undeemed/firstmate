# Chaining a second LLM proxy into a live fleet (headroom + pxpipe)

Audience: operators who already route a fleet through one local Anthropic-API proxy and want to add another proxy hop without disrupting live agents.
This page records the reusable procedure and the ordering rationale.
Machine-specific evidence (exact hosts, pids, unit files, measured savings) belongs in the private task report for that box, not here.

## The pattern

Both proxies speak the Anthropic Messages API on localhost, so they compose by pointing one proxy's upstream at the other while clients keep their existing base URL:

```
client (ANTHROPIC_BASE_URL, unchanged) -> headroom -> pxpipe -> api.anthropic.com
```

- headroom (`uv tool install headroom-ai`, default port 8787) does text-level compression and caching.
  Its `--help` shows no Anthropic upstream override, but its settings store defines `ANTHROPIC_TARGET_API_URL` ("Custom Anthropic API base URL... Overrides https://api.anthropic.com"), env-overridable per process.
  Do not conclude "not configurable" from CLI help alone; search the tool's settings/config store first.
- pxpipe (`npx pxpipe-proxy`, default port 47821) renders request text into PNG image blocks for the models in its allowlist (`PXPIPE_MODELS`) and passes every other model through byte-identical.
  Its own upstream selection is documented in `docs/CLAUDE_CODE_PROVIDER_ROUTING.md` in the pxpipe repo; its default Anthropic upstream is the real API, so it takes the position adjacent to the API.

## Why this order

Headroom-first is preferred whenever the inner proxy's upstream is configurable, for three reasons.
Clients never change: the fleet keeps its existing base URL, and one restart of the inner proxy migrates every client atomically, running sessions included.
Text-level optimization happens before imaging, so the text proxy never sees imaged payloads and cannot re-compress, rewrite, or cache-key-poison PNG blocks.
Each hop stays independently removable because every hop speaks the same API.

If the inner proxy's upstream really is fixed, the fallback is client -> pxpipe -> headroom -> API.
That order requires flipping the client-side `ANTHROPIC_BASE_URL` export (so live agents migrate only as they restart) and verifying with a real request that the downstream text proxy passes image blocks through untouched.

## Cutover rules

1. **Canary first.**
   Bring the whole new chain up on alternate ports beside the live one.
   Run real requests through it (for example `claude -p 'say hi'` with `ANTHROPIC_BASE_URL` pointed at the canary front hop) and confirm a coherent reply, the expected compression evidence in each hop's stats, and no credentials in either proxy's logs.
2. **Restart only the inner proxy.**
   Add the upstream override to the existing proxy's service environment and restart that one process; never restart both proxies at once while the fleet depends on them.
3. **Keep precision models verbatim.**
   Do not add models with weak verbatim recall of imaged text to the pxpipe allowlist when the fleet does precision work; keep them byte-identical pass-through.
4. **One-step rollback.**
   Remove the upstream override from the inner proxy's environment and restart it; clients are untouched either way.
   Keep each hop under its own supervisor (for example a systemd user unit) so one hop can be removed independently.

## Maintaining this file

Keep this page a tool-agnostic procedure plus the ordering facts that motivate it.
When a proxy version changes its upstream configurability or pass-through behavior, re-verify with a live canary and update the rationale here; leave per-box measurements in that box's private report.
