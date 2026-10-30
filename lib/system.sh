#!/usr/bin/env bash

detect_resources() {
  begin_step 'Hardware and resource detection'
  [[ $(uname -m) == x86_64 ]] || fail 'This release currently supports x86_64 systems only.'
  TOTAL_THREADS=$(nproc --all)
  ((TOTAL_THREADS > 0)) || fail 'Could not detect CPU threads.'
  TOTAL_RAM_MB=$(awk '/MemTotal:/ {print int($2/1024)}' /proc/meminfo)
  ((TOTAL_RAM_MB > 0)) || fail 'Could not detect physical RAM.'
  local guests=0
  if command -v qm >/dev/null 2>&1; then guests=$((guests + $(qm list 2>/dev/null | awk 'NR>1 && $3=="running" {n++} END{print n+0}'))); fi
  if command -v pct >/dev/null 2>&1; then guests=$((guests + $(pct list 2>/dev/null | awk 'NR>1 && $2=="running" {n++} END{print n+0}'))); fi

  # CPU allocation and huge-page RAM allocation are independent settings.
  # Only apply the Proxmox 50% default when the operator did not choose a value.
  CPU_PERCENT=${CPU_PERCENT:-75}
  RAM_PERCENT=${RAM_PERCENT:-75}
  [[ $CPU_PERCENT =~ ^[0-9]+$ ]] && ((CPU_PERCENT >= 10 && CPU_PERCENT <= 90)) || fail 'CPU allocation percentage must be between 10 and 90.'
  [[ $RAM_PERCENT =~ ^[0-9]+$ ]] && ((RAM_PERCENT >= 10 && RAM_PERCENT <= 90)) || fail 'Huge-page RAM percentage must be between 10 and 90.'
  if ((guests > 0)) && ((${CPU_PERCENT_EXPLICIT:-0} == 0)); then CPU_PERCENT=50; fi

  THREADS=$((TOTAL_THREADS * CPU_PERCENT / 100))
  ((THREADS > 0)) || THREADS=1
  RAM_BUDGET_MB=$((TOTAL_RAM_MB * RAM_PERCENT / 100))
  log "CPU threads: $TOTAL_THREADS; miner threads: $THREADS; RAM: ${TOTAL_RAM_MB} MiB; huge-page RAM budget: ${RAM_BUDGET_MB} MiB (${RAM_PERCENT}%); running guests: $guests"
}

configure_hugepages() {
  begin_step 'Huge-page configuration'
  local hp1='/sys/kernel/mm/hugepages/hugepages-1048576kB/nr_hugepages'
  local hp2='/sys/kernel/mm/hugepages/hugepages-2048kB/nr_hugepages'
  local current1=0 current2=0 target1=0 target2=0 actual1=0 actual2=0
  [[ -r $hp1 ]] && current1=$(cat "$hp1")
  [[ -r $hp2 ]] && current2=$(cat "$hp2")
  # Allocate up to half the budget to 1 GiB pages first. Existing reservations are never reduced.
  if [[ -w $hp1 ]]; then
    target1=$((RAM_BUDGET_MB / 2 / 1024))
    ((target1 < current1)) && target1=$current1
    printf '%s\n' "$target1" > "$hp1" 2>/dev/null || true
    actual1=$(cat "$hp1" 2>/dev/null || echo "$current1")
  else
    actual1=$current1
  fi
  local remaining_mb=$((RAM_BUDGET_MB - actual1 * 1024))
  ((remaining_mb < 0)) && remaining_mb=0
  if [[ -w $hp2 ]]; then
    target2=$((remaining_mb / 2))
    ((target2 < current2)) && target2=$current2
    printf '%s\n' "$target2" > "$hp2" 2>/dev/null || true
    actual2=$(cat "$hp2" 2>/dev/null || echo "$current2")
  else
    actual2=$current2
  fi
  log "Huge pages now reserved: ${actual1} x 1 GiB and ${actual2} x 2 MiB. Dynamic allocation may be limited by fragmentation."
  if ((actual1 == 0 && actual2 == 0)); then info 'Huge pages could not be reserved dynamically; XMRig will attempt normal allocation.'; fi
}

configure_msr() {
  begin_step 'MSR support check'
  if [[ -d /sys/module/msr ]]; then
    [[ -w /sys/module/msr/parameters/allow_writes ]] && printf '1\n' > /sys/module/msr/parameters/allow_writes 2>/dev/null || true
  else
    modprobe msr 2>/dev/null || { info 'MSR module unavailable; mining will continue without MSR tuning.'; return 0; }
    [[ -w /sys/module/msr/parameters/allow_writes ]] && printf '1\n' > /sys/module/msr/parameters/allow_writes 2>/dev/null || true
  fi
  if ! grep -qx 'msr' /etc/modules 2>/dev/null; then printf 'msr\n' >> /etc/modules; fi
}
