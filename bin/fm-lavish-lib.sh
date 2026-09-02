# shellcheck shell=bash
# Keeps the shared Lavish server answering the hostname this machine is reached
# by, across every respawn.
# Usage: . bin/fm-lavish-lib.sh   then call fm_lavish_prepare_server before any
# `lavish-axi` invocation that may start a server.
#
# Lavish reads its Host allowlist only from `LAVISH_AXI_ALLOWED_HOSTS` in the
# environment of the process that spawned the server, so a long-lived agent
# keeps respawning a server that answers 403 for a hostname that changed after
# it started. docs/configuration.md "Lavish server host allowlist" owns the fix,
# its exposure boundary, and what it deliberately leaves alone.

# This machine's own tailnet identity, MagicDNS name first, read fresh per call.
fm_lavish_tailnet_hosts() {
  command -v tailscale >/dev/null 2>&1 || return 0
  command -v jq >/dev/null 2>&1 || return 0
  tailscale status --json 2>/dev/null \
    | jq -r '(.Self.DNSName // "" | sub("\\.$"; "")), (.Self.TailscaleIPs // [] | .[])' 2>/dev/null \
    | awk 'NF'
}

# Merge the inherited list with that identity, order preserved, no duplicates,
# and export it so the server this process starts carries it.
fm_lavish_export_allowed_hosts() {
  local merged
  merged=$({ tr ' ' '\n' <<<"${LAVISH_AXI_ALLOWED_HOSTS-}"; fm_lavish_tailnet_hosts; } \
    | awk 'NF && !seen[$0]++' | paste -sd' ' -)
  [ -n "$merged" ] || return 0
  export LAVISH_AXI_ALLOWED_HOSTS="$merged"
}

# The address a listener on this port is bound to, empty when nothing listens.
# `lsof -Fn` prints `n*:4387` for a wildcard bind and brackets IPv6 literals.
fm_lavish_listen_address() {
  command -v lsof >/dev/null 2>&1 || return 0
  lsof -nP -iTCP:"$1" -sTCP:LISTEN -Fn 2>/dev/null \
    | sed -n 's/^n\(.*\):[0-9]*$/\1/p' | sed 's/^\*$/0.0.0.0/' | head -1
}

# Health as the server answers it under a given Host, printed verbatim.
fm_lavish_health() {  # <client-address> <port> <host-header>
  curl -sS -m 3 -H "Host: $3" "http://$1:$2/health" 2>/dev/null
}

fm_lavish_shutdown_server() {  # <client-address> <port>
  local deadline
  curl -sS -m 3 -X POST -H "Host: $1" "http://$1:$2/shutdown" >/dev/null 2>&1
  deadline=$((SECONDS + 5))
  while [ "$SECONDS" -lt "$deadline" ]; do
    [ -n "$(fm_lavish_listen_address "$2")" ] || return 0
    sleep 0.2
  done
  return 1
}

# Export the corrected list, and clear a running server out of the way only when
# it genuinely rejects this machine's own hostname.
fm_lavish_prepare_server() {
  local port required listen client
  fm_lavish_export_allowed_hosts
  required=$(fm_lavish_tailnet_hosts | head -1)
  [ -n "$required" ] || return 0
  port=${LAVISH_AXI_PORT:-4387}
  listen=$(fm_lavish_listen_address "$port")
  [ -n "$listen" ] || return 0
  case "$listen" in 0.0.0.0) client=127.0.0.1 ;; *) client=$listen ;; esac
  case "$(fm_lavish_health "$client" "$port" "$client")" in
    *'"app":"lavish-axi"'*) ;;
    *) return 0 ;;
  esac
  case "$(fm_lavish_health "$client" "$port" "$required")" in
    *'"app":"lavish-axi"'*) return 0 ;;
  esac
  # Repairing the allowlist must never narrow the bind: the replacement comes
  # back on the address the running server was reachable on.
  [ -n "${LAVISH_AXI_HOST-}" ] || export LAVISH_AXI_HOST="$listen"
  printf 'lavish: restarting the server on port %s so it answers %s\n' "$port" "$required" >&2
  fm_lavish_shutdown_server "$client" "$port"
}
