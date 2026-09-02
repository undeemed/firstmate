# shellcheck shell=bash
# Keeps the shared Lavish server answering the hostname this machine is reached
# by, across every respawn.
# Usage: . bin/fm-lavish-lib.sh   then call fm_lavish_prepare_server before any
# `lavish-axi` invocation that may start a server.
#
# THE FAULT THIS OWNS. Lavish rejects (403 "forbidden host") any request whose
# `Host` is not in the list it was started with, and that list comes from
# `LAVISH_AXI_ALLOWED_HOSTS` in the environment of whichever process spawned the
# server. Verified against lavish-axi 0.1.52: there is no config file or flag for
# it, and the server is spawned carrying the calling CLI's own environment. A
# long-lived agent that captured its environment before the host list changed
# therefore keeps respawning a server with the stale list, hours or days later,
# and the hostname the operator must use keeps answering 403.
#
# THE FIX. Derive the list from the machine itself at call time instead of
# trusting what a parent captured: this home's tailnet identity is read fresh
# from `tailscale` on every call and merged with the inherited value, so an
# inherited list can only ever be extended, never lost. A running server that
# still rejects that identity is asked to shut down, and the caller's own
# `lavish-axi` invocation then starts the corrected one.
#
# WHAT IT DELIBERATELY DOES NOT DO. It never widens exposure: the bind address
# and the link host stay whatever the operator configured. When it does restart a
# server that was reachable beyond loopback, it first pins `LAVISH_AXI_HOST` to
# that same listening address, so repairing the allowlist can never narrow the
# bind to loopback and black out another home's live boards. A server that
# already accepts the identity is left running, and a non-Lavish listener on the
# port is never touched.
#
# With no tailscale, or with no server running, the merge still happens and the
# reconcile is a no-op: the next start already inherits the corrected list.

FM_LAVISH_SHUTDOWN_TIMEOUT=${FM_LAVISH_SHUTDOWN_TIMEOUT:-5}

fm_lavish_port() { printf '%s\n' "${LAVISH_AXI_PORT:-4387}"; }

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
  local host merged="" seen=$'\n'
  local -a inherited=() derived=()
  read -r -a inherited <<<"${LAVISH_AXI_ALLOWED_HOSTS-}"
  while IFS= read -r host; do derived+=("$host"); done < <(fm_lavish_tailnet_hosts)
  for host in ${inherited[@]+"${inherited[@]}"} ${derived[@]+"${derived[@]}"}; do
    case "$seen" in *$'\n'"$host"$'\n'*) continue ;; esac
    seen+="$host"$'\n'
    merged="${merged:+$merged }$host"
  done
  [ -n "$merged" ] || return 0
  export LAVISH_AXI_ALLOWED_HOSTS="$merged"
}

# The address a listener on this port is bound to, empty when nothing listens.
fm_lavish_listen_address() {
  local port=$1 line addr
  command -v lsof >/dev/null 2>&1 || return 0
  while IFS= read -r line; do
    case "$line" in n*) addr=${line#n} ;; *) continue ;; esac
    addr=${addr%:*}
    case "$addr" in
      "") continue ;;
      "*") printf '0.0.0.0\n' ;;
      *) printf '%s\n' "$addr" ;;
    esac
    return 0
  done < <(lsof -nP -iTCP:"$port" -sTCP:LISTEN -Fn 2>/dev/null)
}

# The address this machine reaches that listener on, and its URL spelling.
fm_lavish_client_address() {
  case "$1" in 0.0.0.0|"::"|"[::]") printf '127.0.0.1\n' ;; *) printf '%s\n' "$1" ;; esac
}

fm_lavish_is_loopback() {
  case "$1" in 127.*|::1|"[::1]"|localhost) return 0 ;; *) return 1 ;; esac
}

fm_lavish_url_host() {
  case "$1" in
    \[*\]) printf '%s\n' "$1" ;;
    *:*) printf '[%s]\n' "$1" ;;
    *) printf '%s\n' "$1" ;;
  esac
}

# Health as the server answers it under a given Host, printed verbatim.
fm_lavish_health() {  # <client-address> <port> <host-header>
  curl -sS -m 3 -H "Host: $3" "http://$(fm_lavish_url_host "$1"):$2/health" 2>/dev/null
}

fm_lavish_shutdown_server() {  # <client-address> <port>
  local deadline
  curl -sS -m 3 -X POST -H "Host: $1" "http://$(fm_lavish_url_host "$1"):$2/shutdown" >/dev/null 2>&1
  deadline=$((SECONDS + FM_LAVISH_SHUTDOWN_TIMEOUT))
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
  port=$(fm_lavish_port)
  listen=$(fm_lavish_listen_address "$port")
  [ -n "$listen" ] || return 0
  client=$(fm_lavish_client_address "$listen")
  case "$(fm_lavish_health "$client" "$port" "$client")" in
    *'"app":"lavish-axi"'*) ;;
    *) return 0 ;;
  esac
  case "$(fm_lavish_health "$client" "$port" "$required")" in
    *'"app":"lavish-axi"'*) return 0 ;;
  esac
  if [ -z "${LAVISH_AXI_HOST-}" ] && ! fm_lavish_is_loopback "$listen"; then
    export LAVISH_AXI_HOST="$listen"
  fi
  printf 'lavish: restarting the server on port %s so it answers %s\n' "$port" "$required" >&2
  fm_lavish_shutdown_server "$client" "$port"
}
