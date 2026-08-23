#!/usr/bin/env bash
# Watch captain-inbox for the dorms.dev GitHub App private key pushed from the captain's laptop,
# then install it for the dorm lane and wake dorm-mate-d9. One-shot: exits after successful install.
set -euo pipefail
FM_HOME="${FM_HOME:-$HOME/Dev/firstmate}"
# Exported once so the wake below runs the send helper with this same home.
export FM_HOME
INBOX="$FM_HOME/state/captain-inbox"
SECRETS="$FM_HOME/state/secrets"
SUPER_ENV="$FM_HOME/super.env"
DEADLINE=$(($(date +%s) + 86400))

while [ "$(date +%s)" -lt "$DEADLINE" ]; do
  PEM=$(find "$INBOX" -maxdepth 1 -name '*.pem' -newermt '2026-08-18' 2>/dev/null | head -1 || true)
  if [ -n "${PEM:-}" ]; then
    # settle: wait until size stable (scp still writing)
    s1=$(stat -c%s "$PEM")
    sleep 2
    s2=$(stat -c%s "$PEM")
    [ "$s1" = "$s2" ] || continue
    if openssl rsa -in "$PEM" -check -noout >/dev/null 2>&1 || openssl pkey -in "$PEM" -noout >/dev/null 2>&1; then
      mkdir -p "$SECRETS" && chmod 700 "$SECRETS"
      install -m 600 "$PEM" "$SECRETS/dorm-gh-app.pem"
      # single-line \n-escaped form + path form; strip any prior entries first
      ONELINE=$(awk 'NF {printf "%s\\n", $0}' "$SECRETS/dorm-gh-app.pem")
      grep -v '^DORM_GH_APP_PRIVATE_KEY' "$SUPER_ENV" >"$SUPER_ENV.tmp"
      printf 'DORM_GH_APP_PRIVATE_KEY="%s"\nDORM_GH_APP_PRIVATE_KEY_PATH=%s\n' "$ONELINE" "$SECRETS/dorm-gh-app.pem" >>"$SUPER_ENV.tmp"
      chmod 600 "$SUPER_ENV.tmp" && mv "$SUPER_ENV.tmp" "$SUPER_ENV"
      shred -u "$PEM" 2>/dev/null || rm -f "$PEM"
      "$FM_HOME/bin/fm-send.sh" dorm-mate-d9 --resolve-key gh-app-private-key \
        "DORM_GH_APP_PRIVATE_KEY landed in super.env (plus _PATH variant at state/secrets/dorm-gh-app.pem, mode 600). Captain pushed the dorms.dev App pem from the laptop. Unblock 10.2 off the stub and switch to the real key." || true
      echo "pem installed $(date -Is)"
      exit 0
    else
      echo "file arrived but is not a valid private key: $PEM (leaving in place)" >&2
      sleep 30
    fi
  fi
  sleep 15
done
echo "pem watcher expired without a pem" >&2
exit 1
