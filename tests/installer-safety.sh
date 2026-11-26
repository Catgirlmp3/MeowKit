#!/usr/bin/env bash
set -Eeuo pipefail
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"

# Tor must be both ordered before the miner and verified before ExecStart.
grep -Fq 'After=network-online.target' "$ROOT/lib/miner.sh"
! grep -Fq 'After=network-online.target ${TOR_UNIT}' "$ROOT/lib/miner.sh"
grep -Fq 'ExecStartPre=/usr/local/sbin/meowkit-tor-check' "$ROOT/lib/miner.sh"
# Runtime Tor preflight must retry slow circuits and have enough systemd startup time.
grep -Fq 'max_attempts=8' "$ROOT/lib/miner.sh"
grep -Fq 'sleep 5' "$ROOT/lib/miner.sh"
grep -Fq 'TimeoutStartSec=480' "$ROOT/lib/miner.sh"
grep -Fq -- '--prepare' "$ROOT/lib/miner.sh"
grep -Fq 'TimeoutStartSec=560' "$ROOT/lib/system.sh"
grep -Fq 'systemctl restart "$SERVICE" || true' "$ROOT/commands/resource-watch.sh"

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

# XMRig is built from a pinned upstream source revision, outside the Tor route.
grep -Fq "XMRIG_COMMIT='b2ca72480c58d197e18c885d9fc1a0c8d517e60a'" "$ROOT/lib/miner.sh"
grep -Fq 'git clone --quiet --depth 1 --branch "v$XMRIG_VERSION" https://github.com/xmrig/xmrig.git' "$ROOT/lib/miner.sh"
grep -Fq 'kDefaultDonateLevel = 0;' "$ROOT/lib/miner.sh"
grep -Fq 'kMinimumDonateLevel = 0;' "$ROOT/lib/miner.sh"
grep -Fq '"donate-level": 0' "$ROOT/lib/miner.sh"
grep -Fq '"donate-over-proxy": 0' "$ROOT/lib/miner.sh"
grep -Fq 'local packages=(curl python3 tar gzip ca-certificates git build-essential cmake libuv1-dev libhwloc-dev)' "$ROOT/lib/tor.sh"
grep -Fq 'cmake --build "$build" --parallel "$build_jobs"' "$ROOT/lib/miner.sh"
! grep -Fq 'curl_tor --output "$asset"' "$ROOT/lib/miner.sh"

# The timer must not pull the miner in, and the watcher must not resurrect it.
! grep -Fq 'Wants=meowkit.service' "$ROOT/lib/system.sh"
grep -Fq 'Miner is not active; leaving it stopped.' "$ROOT/commands/resource-watch.sh"
grep -Fq 'ACTION == --prepare' "$ROOT/commands/resource-watch.sh"

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
