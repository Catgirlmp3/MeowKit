#!/usr/bin/env bash
set -Eeuo pipefail
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"

# Tor must be both ordered before the miner and verified before ExecStart.
grep -Fq 'After=network-online.target ${TOR_UNIT}' "$ROOT/lib/miner.sh"
grep -Fq 'ExecStartPre=/usr/local/sbin/meowkit-tor-check' "$ROOT/lib/miner.sh"
# Runtime Tor preflight must retry slow circuits and have enough systemd startup time.
grep -Fq 'max_attempts=8' "$ROOT/lib/miner.sh"
grep -Fq 'sleep 5' "$ROOT/lib/miner.sh"
grep -Fq 'TimeoutStartSec=210' "$ROOT/lib/miner.sh"

# The generated service must define the exact variable used in ExecStart,
# and only remove systemd's conventional /dev/null mask (not arbitrary links).
grep -Fq 'MEOWKIT_THREADS=$THREADS' "$ROOT/lib/miner.sh"
grep -Fq 'MEOWKIT_THREADS=%s' "$ROOT/lib/miner.sh"
# systemd must expand the current EnvironmentFile thread count on every restart.
grep -Fq -- '--threads=\${MEOWKIT_THREADS}' "$ROOT/lib/miner.sh"
# Silent mode suppresses routine stdout but retains stderr for startup failures.
grep -Fq 'none) LOG_STDOUT=null; LOG_STDERR=journal ;;' "$ROOT/lib/miner.sh"
grep -Fq -- '--silent --show-error --fail --socks5-hostname' "$ROOT/lib/miner.sh"
grep -Fq '[[ $service_link == /dev/null ]]' "$ROOT/lib/miner.sh"
grep -Fq 'Refusing to replace unexpected service symlink' "$ROOT/lib/miner.sh"

# XMRig install must not depend on the unauthenticated GitHub Releases API.
grep -Fq 'https://github.com/xmrig/xmrig/releases/download/v${XMRIG_VERSION}/xmrig-${XMRIG_VERSION}-linux-static-x64.tar.gz' "$ROOT/lib/miner.sh"
grep -Fq "fc6f8ae5f64e4f17481f7e3be29a1c56949f216a998414188003eae1db20c9e5" "$ROOT/lib/miner.sh"
! grep -Fq 'api.github.com/repos/xmrig/xmrig/releases' "$ROOT/lib/miner.sh"

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

# Runtime huge-page allocation must avoid 1 GiB compaction and bound 2 MiB writes.
grep -Fq 'Runtime allocation of 1 GiB pages can trigger lengthy synchronous memory' "$ROOT/commands/hugepages.sh"
grep -Fq 'timeout --signal=TERM --kill-after=2s 8s' "$ROOT/commands/hugepages.sh"
grep -Fq 'ONE_GB=0' "$ROOT/commands/hugepages.sh"
grep -Fq 'if (( TARGET_MB >= 2600 && ACTUAL1 >= 1 )); then ONE_GB=1; fi' "$ROOT/commands/hugepages.sh"
! grep -Fq ' > "$HP1"' "$ROOT/commands/hugepages.sh"
