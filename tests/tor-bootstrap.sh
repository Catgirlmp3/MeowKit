#!/usr/bin/env bash
set -Eeuo pipefail
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
TOR_SOURCE="$ROOT/lib/tor.sh"

# Tor's Debian systemd unit can be Type=notify. Never wait synchronously for
# systemd READY during installer bootstrap; poll the SOCKS/API endpoint instead.
grep -Fq 'systemctl --no-block restart "$TOR_UNIT"' "$TOR_SOURCE"
! grep -Fq 'systemctl restart "$TOR_UNIT"' "$TOR_SOURCE"
grep -Fq 'local deadline=$((SECONDS + 180))' "$TOR_SOURCE"
grep -Fq 'journalctl -u "$TOR_UNIT" -n 40 --no-pager' "$TOR_SOURCE"

echo "Tor bootstrap non-blocking startup regression checks passed."

# A failed Tor connectivity probe is an expected retry, not an installer-fatal
# command-substitution failure under set -E / ERR-trap inheritance.
! grep -Fq 'if response=$(curl' "$TOR_SOURCE"
grep -Fq 'response_file=$(mktemp /tmp/meowkit-tor-check.' "$TOR_SOURCE"
grep -Fq 'if curl --connect-timeout 3' "$TOR_SOURCE"
grep -Fq 'python3 -c' "$TOR_SOURCE"

