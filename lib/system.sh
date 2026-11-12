#!/usr/bin/env bash

detect_resources() {
  begin_step 'Hardware and resource detection'
  [[ $(uname -m) == x86_64 ]] || fail 'This release currently supports x86_64 systems only.'
  TOTAL_THREADS=$(nproc 2>/dev/null || nproc --all)
  ((TOTAL_THREADS > 0)) || fail 'Could not detect available CPU threads.'
  TOTAL_RAM_MB=$(awk '/MemTotal:/ {print int($2/1024)}' /proc/meminfo)
  MEM_AVAIL_MB=$(awk '/MemAvailable:/ {print int($2/1024)}' /proc/meminfo)
  ((TOTAL_RAM_MB > 0 && MEM_AVAIL_MB > 0)) || fail 'Could not read system memory information.'
  local guests=0
  if command -v qm >/dev/null 2>&1; then guests=$((guests + $(qm list 2>/dev/null | awk 'NR>1 && $3=="running" {n++} END{print n+0}'))); fi
  if command -v pct >/dev/null 2>&1; then guests=$((guests + $(pct list 2>/dev/null | awk 'NR>1 && $2=="running" {n++} END{print n+0}'))); fi
  CPU_PERCENT=${CPU_PERCENT:-30}
  if [[ ${VM_MODE:-auto} == shared ]] || { [[ ${VM_MODE:-auto} == auto ]] && ((guests > 0)) && ((${CPU_PERCENT_EXPLICIT:-0} == 0)); }; then CPU_PERCENT=50; fi
  THREADS=$((TOTAL_THREADS * CPU_PERCENT / 100))
  ((THREADS > 0)) || THREADS=1
  if [[ -n ${THREADS_OVERRIDE:-} ]]; then
    ((THREADS_OVERRIDE >= 1 && THREADS_OVERRIDE <= TOTAL_THREADS)) || fail "--threads must be between 1 and $TOTAL_THREADS."
    THREADS=$THREADS_OVERRIDE
  fi
  [[ $RAM_PERCENT =~ ^[0-9]+$ ]] && ((RAM_PERCENT >= 10 && RAM_PERCENT <= 90)) || fail 'RAM percentage must be 10-90.'
  CPU_QUOTA=$((THREADS * 100))
  log "CPUs: $TOTAL_THREADS; miner threads: $THREADS; RAM: $TOTAL_RAM_MB MiB; available: $MEM_AVAIL_MB MiB; guests: $guests"
}

configure_hugepages() {
  begin_step 'Automatic huge-page sizing'
  install -d -m 755 "$MEOWKIT_DIR" /usr/local/sbin || { warn 'Cannot create huge-page configuration; continuing without huge-page automation.'; return 0; }
  cat > "$MEOWKIT_DIR/hugepages.conf" <<EOF
RAM_PERCENT=$RAM_PERCENT
THREADS=$THREADS
EOF
  chmod 600 "$MEOWKIT_DIR/hugepages.conf" || warn 'Could not restrict huge-page config permissions.'
  cat > /usr/local/sbin/meowkit-hugepages <<'EOFHP'
#!/usr/bin/env bash
set -u
CONFIG=/etc/meowkit/hugepages.conf
HP2=/sys/kernel/mm/hugepages/hugepages-2048kB/nr_hugepages
HP1=/sys/kernel/mm/hugepages/hugepages-1048576kB/nr_hugepages
RAM_PERCENT=75; THREADS=1
[[ -r $CONFIG ]] && source "$CONFIG"
[[ $RAM_PERCENT =~ ^[0-9]+$ ]] || RAM_PERCENT=75
[[ $THREADS =~ ^[0-9]+$ ]] || THREADS=1
TOTAL=$(awk '/MemTotal:/ {print int($2/1024)}' /proc/meminfo)
AVAIL=$(awk '/MemAvailable:/ {print int($2/1024)}' /proc/meminfo)
# Keep at least 20% of physical RAM (and at least 1 GiB) available to the host.
RESERVE=$((TOTAL / 5)); ((RESERVE < 1024)) && RESERVE=1024
SAFE=$((AVAIL - RESERVE)); ((SAFE < 0)) && SAFE=0
BUDGET=$((SAFE * RAM_PERCENT / 100))
# RandomX dataset is ~2.1 GiB; reserve a modest margin and per-thread scratch.
TARGET=$((2600 + THREADS * 4))
((TARGET > BUDGET)) && TARGET=$BUDGET
CURRENT1=0; CURRENT2=0
[[ -r $HP1 ]] && CURRENT1=$(cat "$HP1" 2>/dev/null || echo 0)
[[ -r $HP2 ]] && CURRENT2=$(cat "$HP2" 2>/dev/null || echo 0)
# Do not claim existing global reservations as MeowKit-owned or shrink them.
# Opportunistically add one 1GiB page only if the full target budget permits it.
ADD1=0
if [[ -w $HP1 ]] && ((TARGET >= 2600 && CURRENT1 == 0)); then
  printf '1\n' > "$HP1" 2>/dev/null && ADD1=1 || true
fi
REMAINING=$((TARGET - (CURRENT1 + ADD1) * 1024))
((REMAINING < 0)) && REMAINING=0
TARGET2=$(( (REMAINING + 1) / 2 ))
if [[ -w $HP2 ]] && ((TARGET2 > CURRENT2)); then
  printf '%s\n' "$TARGET2" > "$HP2" 2>/dev/null || echo 'MeowKit: 2 MiB page reservation failed; existing pages retained.' >&2
fi
echo "MeowKit: 1GiB pages currently $((CURRENT1 + ADD1)) (added $ADD1); 2MiB pages currently $(cat "$HP2" 2>/dev/null || echo "$CURRENT2")."
((ADD1 == 1)) || echo 'MeowKit: 1GiB pages unavailable or not safely allocatable; 2MiB/normal-page fallback selected.'
EOFHPP
  chmod 755 /usr/local/sbin/meowkit-hugepages || { warn 'Could not install huge-page helper; continuing without it.'; return 0; }
  /usr/local/sbin/meowkit-hugepages || warn 'Huge-page helper failed; continuing with kernel defaults.'
}

configure_msr() {
  begin_step 'MSR support (optional)'
  install -d -m 755 /etc/modules-load.d /etc/modprobe.d || { warn 'Cannot configure MSR; continuing without it.'; return 0; }
  printf 'msr\n' > /etc/modules-load.d/meowkit-msr.conf || { warn 'Cannot write MSR module config.'; return 0; }
  printf 'options msr allow_writes=on\n' > /etc/modprobe.d/meowkit-msr.conf || warn 'Cannot write MSR options.'
  if modprobe msr 2>/dev/null; then info 'MSR module loaded where supported.'; else warn 'MSR unavailable/blocked; continuing without MSR tuning.'; fi
}
