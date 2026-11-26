#!/usr/bin/env bash

detect_resources() {
  begin_step 'Hardware and resource detection'
  [[ $(uname -m) == x86_64 ]] || fail 'This release currently supports x86_64 systems only.'
  TOTAL_THREADS=$(nproc --all)
  (( TOTAL_THREADS > 0 )) || fail 'Could not detect CPU threads.'
  TOTAL_RAM_MB=$(awk '/MemTotal:/ {print int($2/1024)}' /proc/meminfo)
  (( TOTAL_RAM_MB > 0 )) || fail 'Could not detect physical RAM.'

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

  install -d -m 750 "$MEOWKIT_DIR"
  cat > "$MEOWKIT_DIR/resources.conf" <<EOFRES
CPU_PERCENT=$CPU_PERCENT
RAM_PERCENT=$RAM_PERCENT
VM_CPU_REDUCTION_PERCENT=$VM_CPU_REDUCTION_PERCENT
EOFRES
  chmod 600 "$MEOWKIT_DIR/resources.conf"
  log "CPU threads: $TOTAL_THREADS; baseline miner threads: $THREADS; CPU quota: ${CPU_QUOTA}%; RAM: ${TOTAL_RAM_MB} MiB; running Proxmox guests: $guests"
}

configure_hugepages() {
  begin_step 'Huge-page calculation and reservation'
  install -d -m 750 "$MEOWKIT_DIR" /usr/local/sbin

  if [[ ${REPAIR:-0} != 1 || ! -r "$MEOWKIT_DIR/hugepages.conf" ]]; then
    cat > "$MEOWKIT_DIR/hugepages.conf" <<EOFHP
RAM_PERCENT=$RAM_PERCENT
HOST_RESERVE_MB=2048
EOFHP
    chmod 600 "$MEOWKIT_DIR/hugepages.conf"
  fi

  install -m 0755 "$ROOT/commands/hugepages.sh" /usr/local/sbin/meowkit-hugepages
  /usr/local/sbin/meowkit-hugepages || info 'Huge-page helper reported a problem; XMRig will use whatever page sizes are available.'
  ONE_GB_PAGES=0
  if [[ -r "$MEOWKIT_DIR/hugepages.conf" ]]; then
    # This state file is written by the MeowKit helper.
    # shellcheck source=/dev/null
    source "$MEOWKIT_DIR/hugepages.conf"
    ONE_GB_PAGES=${ONE_GB_PAGES:-0}
  fi
  [[ "$ONE_GB_PAGES" == 1 ]] && info '1 GiB RandomX pages are available.' || info '1 GiB pages unavailable; 2 MiB huge pages remain enabled as the fallback.'
}

configure_msr() {
  begin_step 'MSR support and write permissions'
  install -d -m 755 /etc/modules-load.d /etc/modprobe.d /usr/local/sbin

  printf 'msr\n' > /etc/modules-load.d/meowkit-msr.conf
  printf 'options msr allow_writes=on\n' > /etc/modprobe.d/meowkit-msr.conf
  install -m 0755 "$ROOT/commands/msr-enable.sh" /usr/local/sbin/meowkit-msr-enable

  cat > /etc/systemd/system/meowkit-msr.service <<'EOFMSR'
[Unit]
Description=Enable Linux MSR access for MeowKit
After=systemd-modules-load.service
Before=meowkit.service

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/meowkit-msr-enable
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOFMSR
  chmod 644 /etc/systemd/system/meowkit-msr.service

  systemctl daemon-reload || fail 'systemd could not reload the MSR unit.'
  systemctl enable --now meowkit-msr.service >/dev/null 2>&1 || info 'MSR setup service could not be enabled; MeowKit will continue without MSR tuning.'
}

configure_schedule() {
  begin_step 'Local-time mining schedule'
  install -d -m 750 "$MEOWKIT_DIR" /usr/local/sbin

  local detected_threads=$THREADS
  local detected_total=$TOTAL_THREADS
  local schedule_file="$MEOWKIT_DIR/schedule.conf"

  SCHEDULE_ENABLED=1
  DAY_START=08:00
  DAY_END=16:00
  DAY_THREADS=$((detected_threads * DAY_PERCENT / 100))
  ((DAY_THREADS > 0)) || DAY_THREADS=1
  TIMEZONE=Europe/Dublin
  if [[ -r "$schedule_file" ]]; then
    # Preserve user-edited schedule settings during repair.
    # shellcheck source=/dev/null
    source "$schedule_file"
  fi
  # A saved schedule contains the previous machine's baseline; never let it
  # overwrite the just-detected values used by this repair run.
  THREADS=$detected_threads
  TOTAL_THREADS=$detected_total

  DAY_PERCENT=${DAY_PERCENT:-40}
  [[ $DAY_PERCENT =~ ^[0-9]+$ ]] && ((DAY_PERCENT >= 1 && DAY_PERCENT <= 100)) || DAY_PERCENT=40
  DAY_THREADS=$((detected_threads * DAY_PERCENT / 100))
  ((DAY_THREADS > 0)) || DAY_THREADS=1
  cat > "$schedule_file" <<EOFSCHEDULE
SCHEDULE_ENABLED=${SCHEDULE_ENABLED:-1}
DAY_START=${DAY_START:-08:00}
DAY_END=${DAY_END:-16:00}
DAY_PERCENT=$DAY_PERCENT
DAY_THREADS=$DAY_THREADS
BASE_THREADS=$detected_threads
TOTAL_THREADS=$detected_total
TIMEZONE=${TIMEZONE:-Europe/Dublin}
EOFSCHEDULE
  chmod 600 "$schedule_file"

  install -m 0755 "$ROOT/commands/schedule.sh" /usr/local/sbin/meowkit-schedule

  cat > /etc/systemd/system/meowkit-schedule.service <<'EOFSVC'
[Unit]
Description=Apply MeowKit time-based mining thread schedule

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/meowkit-schedule --apply
TimeoutStartSec=300
Nice=10
EOFSVC

  cat > /etc/systemd/system/meowkit-schedule.timer <<'EOFTIMER'
[Unit]
Description=Check MeowKit mining schedule every minute

[Timer]
OnCalendar=*-*-* *:*:00
Persistent=true
AccuracySec=1s
Unit=meowkit-schedule.service

[Install]
WantedBy=timers.target
EOFTIMER

  chmod 644 /etc/systemd/system/meowkit-schedule.service /etc/systemd/system/meowkit-schedule.timer
  systemctl daemon-reload || fail 'systemd could not reload the mining schedule units.'
  info "Schedule configured: ${DAY_START:-08:00}-${DAY_END:-16:00}, ${DAY_THREADS:-8} threads during the window, $detected_threads outside it, timezone ${TIMEZONE:-Europe/Dublin}."
}
