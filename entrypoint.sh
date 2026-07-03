#!/bin/bash
set -e

if [ "$(id -u)" = "0" ]; then
  if command -v iptables &>/dev/null; then
    if ! /usr/local/bin/init-firewall.sh; then
      echo "WARNING: firewall setup failed (container may be missing NET_ADMIN/NET_RAW)." >&2
      echo "Continuing WITHOUT outbound network restrictions." >&2
    fi
  fi

  # Fix ownership of the persisted auth volume on first run / after a
  # UID change, so the non-root user can read and write it.
  if [ -d /home/claude/.claude ]; then
    chown -R claude:claude /home/claude/.claude 2>/dev/null || true
  fi

  # Drop root permanently for the rest of the process's life. No sudo is
  # configured for the claude user, so there's no path back to root from
  # here even if the process is compromised.
  exec gosu claude "$@"
fi

exec "$@"
