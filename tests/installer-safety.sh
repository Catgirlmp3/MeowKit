#!/usr/bin/env bash
set -Eeuo pipefail
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"

# Tor must be both ordered before the miner and verified before ExecStart.
grep -Fq 'After=network-online.target ${TOR_UNIT}' "$ROOT/lib/miner.sh"
grep -Fq 'ExecStartPre=/usr/local/sbin/meowkit-tor-check' "$ROOT/lib/miner.sh"

# The timer must not pull the miner in, and the watcher must not resurrect it.
! grep -Fq 'Wants=meowkit.service' "$ROOT/lib/system.sh"
grep -Fq 'Miner is not active; leaving it stopped.' "$ROOT/commands/resource-watch.sh"

# Restore must write a real newline, not a literal backslash-n.
grep -Fq "printf '%s\n' \"\$value\"" "$ROOT/commands/hugepages.sh"

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/meowkit" "$TMP/bin"
cat > "$TMP/meowkit/resource-profile.conf" <<'EOF'
BASE_THREADS=8
TOTAL_THREADS=8
VM_CPU_REDUCTION_PERCENT=50
SCHEDULE_ENABLED=0
DAY_START=08:00
DAY_END=16:00
DAY_PERCENT=40
TIMEZONE=UTC
RAM_PERCENT=75
EOF
cat > "$TMP/bin/qm" <<'EOF'
#!/usr/bin/env bash
exit 1
EOF
chmod +x "$TMP/bin/qm"
if MEOWKIT_DIR="$TMP/meowkit" PATH="$TMP/bin:$PATH" bash "$ROOT/commands/resource-watch.sh" --dry-run >"$TMP/out" 2>&1; then
  echo 'FAIL: watcher accepted a failed qm list command' >&2
  exit 1
fi
grep -Fq 'qm list failed; refusing to guess guest state.' "$TMP/out"
echo 'PASS installer safety checks: Tor gate, no miner resurrection, huge-page restore format, fail-closed VM detection'
