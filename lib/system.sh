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
  CPU_PERCENT=${CPU_PERCENT:-75}
  RAM_PERCENT=${RAM_PERCENT:-75}
  [[ $CPU_PERCENT =~ ^[0-9]+$ ]] && ((CPU_PERCENT >= 10 && CPU_PERCENT <= 90)) || fail 'CPU allocation percentage must be between 10 and 90.'
  [[ $RAM_PERCENT =~ ^[0-9]+$ ]] && ((RAM_PERCENT >= 10 && RAM_PERCENT <= 90)) || fail 'Huge-page RAM percentage must be between 10 and 90.'
  if ((guests > 0)) && ((${CPU_PERCENT_EXPLICIT:-0} == 0)); then CPU_PERCENT=50; fi
  THREADS=$((TOTAL_THREADS * CPU_PERCENT / 100))
  ((THREADS > 0)) || THREADS=1
  CPU_QUOTA=$((TOTAL_THREADS * CPU_PERCENT))
  log "CPU threads: $TOTAL_THREADS; miner threads: $THREADS; CPU quota: ${CPU_QUOTA}%; RAM: ${TOTAL_RAM_MB} MiB; running Proxmox guests: $guests"
}

configure_hugepages() {
  begin_step '2 MiB huge-page allocation'
  install -d -m 755 "$MEOWKIT_DIR" /usr/local/sbin
  printf 'RAM_PERCENT=%s\n' "$RAM_PERCENT" > "$MEOWKIT_DIR/hugepages.conf"
  chmod 600 "$MEOWKIT_DIR/hugepages.conf"
  cat > /usr/local/sbin/meowkit-hugepages <<'EOFHP'
#!/usr/bin/env bash
set -u
CONFIG=/etc/meowkit/hugepages.conf
HP=/sys/kernel/mm/hugepages/hugepages-2048kB/nr_hugepages
[[ -r $HP && -w $HP ]] || { echo 'MeowKit: 2 MiB huge pages are unavailable.' >&2; exit 0; }
RAM_PERCENT=75
[[ -r $CONFIG ]] && source "$CONFIG"
[[ $RAM_PERCENT =~ ^[0-9]+$ ]] || RAM_PERCENT=75
(( RAM_PERCENT >= 10 && RAM_PERCENT <= 90 )) || RAM_PERCENT=75
MEM_TOTAL_MB=$(awk '/MemTotal:/ {print int($2/1024)}' /proc/meminfo)
HOST_RESERVE_MB=2048
GUEST_RESERVE_MB=0
if command -v qm >/dev/null 2>&1; then
  while read -r vmid; do
    [[ $vmid =~ ^[0-9]+$ ]] || continue
    mem=$(qm config "$vmid" 2>/dev/null | awk -F: '$1=="memory" {gsub(/[[:space:]]/,"",$2); print $2; exit}')
    [[ $mem =~ ^[0-9]+$ ]] && GUEST_RESERVE_MB=$((GUEST_RESERVE_MB + mem))
  done < <(qm list 2>/dev/null | awk 'NR>1 && $3=="running" {print $1}')
fi
if command -v pct >/dev/null 2>&1; then
  while read -r ctid; do
    [[ $ctid =~ ^[0-9]+$ ]] || continue
    mem=$(pct config "$ctid" 2>/dev/null | awk -F: '$1=="memory" {gsub(/[[:space:]]/,"",$2); print $2; exit}')
    [[ $mem =~ ^[0-9]+$ ]] && GUEST_RESERVE_MB=$((GUEST_RESERVE_MB + mem))
  done < <(pct list 2>/dev/null | awk 'NR>1 && $2=="running" {print $1}')
fi
SAFE_MB=$((MEM_TOTAL_MB - HOST_RESERVE_MB - GUEST_RESERVE_MB))
(( SAFE_MB > 0 )) || { echo "MeowKit: no safe huge-page budget (host reserve ${HOST_RESERVE_MB} MiB, guest reserve ${GUEST_RESERVE_MB} MiB)." >&2; exit 0; }
BUDGET_MB=$((SAFE_MB * RAM_PERCENT / 100))
TARGET_PAGES=$((BUDGET_MB / 2))
CURRENT_PAGES=$(cat "$HP")
if (( TARGET_PAGES > CURRENT_PAGES )); then printf '%s\n' "$TARGET_PAGES" > "$HP" 2>/dev/null || true; fi
ACTUAL_PAGES=$(cat "$HP" 2>/dev/null || printf '%s' "$CURRENT_PAGES")
echo "MeowKit: 2 MiB huge pages: ${ACTUAL_PAGES} reserved (budget ${BUDGET_MB} MiB; Proxmox guest reserve ${GUEST_RESERVE_MB} MiB)."
EOFHP
  chmod 755 /usr/local/sbin/meowkit-hugepages
  /usr/local/sbin/meowkit-hugepages || info 'Huge-page allocation helper reported an issue; continuing without the optimisation.'
}

configure_msr() {
  begin_step 'MSR support'
  install -d -m 755 /etc/modules-load.d /etc/modprobe.d
  printf 'msr\n' > /etc/modules-load.d/meowkit-msr.conf
  printf 'options msr allow_writes=on\n' > /etc/modprobe.d/meowkit-msr.conf
  if modprobe msr 2>/dev/null; then
    if [[ -w /sys/module/msr/parameters/allow_writes ]]; then
      printf '1\n' > /sys/module/msr/parameters/allow_writes 2>/dev/null || true
      info 'MSR module loaded; write support enabled where provided by the kernel.'
    else
      info 'MSR module loaded; this kernel does not expose allow_writes. Continuing.'
    fi
  else
    info 'MSR module unavailable or blocked by the kernel; continuing without MSR tuning.'
  fi
}
