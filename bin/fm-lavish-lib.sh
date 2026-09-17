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
# fm_lavish_prepare_server always returns 0: a stale server it cannot clear is
# reported on stderr and left for the caller's own lavish-axi invocation to
# surface.

# This machine's own tailnet identity, MagicDNS name first, read fresh per call.
fm_lavish_tailnet_hosts() {
  command -v tailscale >/dev/null 2>&1 || return 0
  command -v jq >/dev/null 2>&1 || return 0
  tailscale status --json 2>/dev/null \
    | jq -r '(.Self.DNSName // "" | sub("\\.$"; "")), (.Self.TailscaleIPs // [] | .[])' 2>/dev/null \
    | awk 'NF'
}

# The address a listener on this port is bound to, empty when nothing listens.
# `lsof -Fn` prints `n*:4387` for a wildcard bind and brackets IPv6 literals.
fm_lavish_listen_address() {
  command -v lsof >/dev/null 2>&1 || return 0
  lsof -nP -iTCP:"$1" -sTCP:LISTEN -Fn 2>/dev/null \
    | sed -n 's/^n\(.*\):[0-9]*$/\1/p' | sed 's/^\*$/0.0.0.0/' | head -1
}

# Whether the server on this port answers as Lavish under a given Host.
fm_lavish_is_lavish() {  # <client-address> <port> <host-header>
  curl -sS -m 3 -H "Host: $3" "http://$1:$2/health" 2>/dev/null | grep -q '"app":"lavish-axi"'
}

# Every host the running server still answers for, one per line, probed with
# each candidate hostname this caller can know about.
fm_lavish_served_hosts() {  # <client-address> <port> <candidate-list>
  local candidate
  {
    tr ' ' '\n' <<<"$3"
    printf '%s\n' "$1" "${LAVISH_AXI_LINK_HOST-}"
    hostname -I 2>/dev/null || true
    hostname -f 2>/dev/null || true
  } | tr ' ' '\n' | awk 'NF && !seen[$0]++' \
    | while IFS= read -r candidate; do
        if fm_lavish_is_lavish "$1" "$2" "$candidate"; then
          printf '%s\n' "$candidate"
        fi
      done
}

fm_lavish_shutdown_server() {  # <client-address> <port>
  local deadline
  curl -sS -m 3 -X POST -H "Host: $1" "http://$1:$2/shutdown" >/dev/null 2>&1 || true
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
  local hosts merged required port listen client served link
  hosts=$(fm_lavish_tailnet_hosts)
  merged=$({ tr ' ' '\n' <<<"${LAVISH_AXI_ALLOWED_HOSTS-}"; printf '%s\n' "$hosts"; } \
    | awk 'NF && !seen[$0]++' | paste -sd' ' -)
  [ -n "$merged" ] && export LAVISH_AXI_ALLOWED_HOSTS="$merged"
  required=$(printf '%s\n' "$hosts" | head -1)
  [ -n "$required" ] || return 0
  port=${LAVISH_AXI_PORT:-4387}
  listen=$(fm_lavish_listen_address "$port")
  [ -n "$listen" ] || return 0
  case "$listen" in 0.0.0.0) client=127.0.0.1 ;; *) client=$listen ;; esac
  fm_lavish_is_lavish "$client" "$port" "$client" || return 0
  fm_lavish_is_lavish "$client" "$port" "$required" && return 0
  served=$(fm_lavish_served_hosts "$client" "$port" "$merged")
  if [ -n "$served" ]; then
    merged=$({ tr ' ' '\n' <<<"$merged"; printf '%s\n' "$served"; } \
      | awk 'NF && !seen[$0]++' | paste -sd' ' -)
    export LAVISH_AXI_ALLOWED_HOSTS="$merged"
    if [ -z "${LAVISH_AXI_LINK_HOST-}" ]; then
      link=$(printf '%s\n' "$served" \
        | awk '$0 != "127.0.0.1" && $0 != "::1" && $0 != "localhost"' | head -1)
      [ -z "$link" ] || export LAVISH_AXI_LINK_HOST="$link"
    fi
  fi
  # Repairing the allowlist must never narrow the bind: the replacement comes
  # back on the address the running server was reachable on.
  [ -n "${LAVISH_AXI_HOST-}" ] || export LAVISH_AXI_HOST="$listen"
  printf 'lavish: restarting the server on port %s so it answers %s\n' "$port" "$required" >&2
  fm_lavish_shutdown_server "$client" "$port" && return 0
  listen=$(fm_lavish_listen_address "$port")
  [ -n "$listen" ] || return 0
  case "$listen" in 0.0.0.0) client=127.0.0.1 ;; *) client=$listen ;; esac
  fm_lavish_is_lavish "$client" "$port" "$required" && return 0
  printf 'lavish: the server on port %s did not shut down and still rejects %s\n' "$port" "$required" >&2
  return 0
}
