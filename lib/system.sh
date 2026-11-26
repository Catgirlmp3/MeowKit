#!/usr/bin/env bash

detect_resources() {
  begin_step 'Hardware and resource detection'
  [[ $(uname -m) == x86_64 ]] || fail 'This release currently supports x86_64 systems only.'
  TOTAL_THREADS=$(nproc 2>/dev/null || nproc --all)
  ((TOTAL_THREADS > 0)) || fail 'Could not detect available CPU threads.'
  TOTAL_RAM_MB=$(awk '/MemTotal:/ {print int($2/1024)}' /proc/meminfo)
  MEM_AVAIL_MB=$(awk '/MemAvailable:/ {print int($2/1024)}' /proc/meminfo)
  ((TOTAL_RAM_MB > 0 && MEM_AVAIL_MB > 0)) || fail 'Could not read system memory information.'

  CPU_PERCENT=${CPU_PERCENT:-75}
  RAM_PERCENT=${RAM_PERCENT:-75}
  VM_CPU_REDUCTION_PERCENT=${VM_CPU_REDUCTION_PERCENT:-50}
  SCHEDULE_ENABLED=${SCHEDULE_ENABLED:-1}
  DAY_START=${DAY_START:-08:00}
  DAY_END=${DAY_END:-16:00}
  DAY_PERCENT=${DAY_PERCENT:-40}
  TIMEZONE=${TIMEZONE:-Europe/Dublin}
  [[ $CPU_PERCENT =~ ^[0-9]+$ ]] && ((CPU_PERCENT >= 1 && CPU_PERCENT <= 100)) || fail 'CPU allocation must be 1-100%.'
  [[ $RAM_PERCENT =~ ^[0-9]+$ ]] && ((RAM_PERCENT >= 1 && RAM_PERCENT <= 100)) || fail 'Huge-page RAM budget must be 1-100%.'
  [[ $VM_CPU_REDUCTION_PERCENT =~ ^[0-9]+$ ]] && ((VM_CPU_REDUCTION_PERCENT >= 0 && VM_CPU_REDUCTION_PERCENT <= 90)) || fail 'VM CPU reduction must be 0-90%.'
  [[ $SCHEDULE_ENABLED == 0 || $SCHEDULE_ENABLED == 1 ]] || fail 'Schedule enabled must be 0 or 1.'
  [[ $DAY_PERCENT =~ ^[0-9]+$ ]] && ((DAY_PERCENT >= 1 && DAY_PERCENT <= 100)) || fail 'Scheduled CPU percentage must be 1-100%.'
  for t in "$DAY_START" "$DAY_END"; do [[ $t =~ ^([01][0-9]|2[0-3]):[0-5][0-9]$ ]] || fail "Invalid schedule time: $t"; done
  [[ $DAY_START != "$DAY_END" ]] || fail 'Schedule start and end must differ.'
  [[ -e /usr/share/zoneinfo/$TIMEZONE ]] || fail "Unknown timezone: $TIMEZONE."

  if [[ ${VM_MODE:-auto} == shared ]]; then CPU_PERCENT=50; fi
  THREADS=$((TOTAL_THREADS * CPU_PERCENT / 100))
  ((THREADS > 0)) || THREADS=1
  if [[ -n ${THREADS_OVERRIDE:-} ]]; then
    [[ $THREADS_OVERRIDE =~ ^[0-9]+$ ]] && ((THREADS_OVERRIDE >= 1 && THREADS_OVERRIDE <= TOTAL_THREADS)) || fail "--threads must be between 1 and $TOTAL_THREADS."
    THREADS=$THREADS_OVERRIDE
    CPU_PERCENT=$((THREADS * 100 / TOTAL_THREADS))
    (( CPU_PERCENT > 0 )) || CPU_PERCENT=1
  fi
  BASE_THREADS=$THREADS
  CPU_QUOTA=$((THREADS * 100))

  install -d -m 750 "$MEOWKIT_DIR"
  cat > "$MEOWKIT_DIR/resource-profile.conf" <<EOFPROFILE
BASE_THREADS=$BASE_THREADS
TOTAL_THREADS=$TOTAL_THREADS
CPU_PERCENT=$CPU_PERCENT
RAM_PERCENT=$RAM_PERCENT
VM_CPU_REDUCTION_PERCENT=$VM_CPU_REDUCTION_PERCENT
SCHEDULE_ENABLED=$SCHEDULE_ENABLED
DAY_START=$DAY_START
DAY_END=$DAY_END
DAY_PERCENT=$DAY_PERCENT
TIMEZONE=$TIMEZONE
EOFPROFILE
  chmod 600 "$MEOWKIT_DIR/resource-profile.conf"
  log "Baseline: $THREADS/$TOTAL_THREADS threads; CPU $CPU_PERCENT%; RAM budget $RAM_PERCENT%; VM reduction $VM_CPU_REDUCTION_PERCENT%; schedule $SCHEDULE_ENABLED ($DAY_START-$DAY_END at $DAY_PERCENT%)."
}

configure_hugepages() {
  begin_step 'Guest-aware huge-page sizing'
  install -d -m 750 "$MEOWKIT_DIR" /usr/local/sbin || { warn 'Cannot create huge-page configuration; continuing without huge-page automation.'; return 0; }
  cat > "$MEOWKIT_DIR/hugepages.conf" <<EOFHP
RAM_PERCENT=$RAM_PERCENT
THREADS=$THREADS
HOST_RESERVE_MB=2048
EOFHP
  chmod 600 "$MEOWKIT_DIR/hugepages.conf" || warn 'Could not restrict huge-page config permissions.'
  install -m 0755 "$ROOT/commands/hugepages.sh" /usr/local/sbin/meowkit-hugepages || { warn 'Could not install huge-page helper; continuing without it.'; return 0; }
  # Huge-page setup runs once config.json exists, avoiding duplicate allocation work.
}

configure_resource_manager() {
  begin_step 'Adaptive Proxmox resource manager'
  install -d -m 755 /usr/local/sbin /etc/systemd/system
  install -m 0755 "$ROOT/commands/resource-watch.sh" /usr/local/sbin/meowkit-resource-watch || fail 'Could not install resource watcher.'
  cat > /etc/systemd/system/meowkit-resource-watch.service <<'EOFSVC'
[Unit]
Description=MeowKit adaptive CPU and huge-page resource manager
After=meowkit.service

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/meowkit-resource-watch --apply
TimeoutStartSec=420
Nice=10
EOFSVC
  cat > /etc/systemd/system/meowkit-resource-watch.timer <<'EOFTIMER'
[Unit]
Description=Check MeowKit schedule and Proxmox guest state

[Timer]
OnBootSec=15s
OnUnitActiveSec=15s
AccuracySec=2s
Unit=meowkit-resource-watch.service

[Install]
WantedBy=timers.target
EOFTIMER
  chmod 644 /etc/systemd/system/meowkit-resource-watch.service /etc/systemd/system/meowkit-resource-watch.timer
  systemctl daemon-reload || fail 'systemd could not load the adaptive resource manager units.'
}

configure_msr() {
  begin_step 'MSR support (optional)'
  install -d -m 755 /etc/modules-load.d /etc/modprobe.d || { warn 'Cannot configure MSR; continuing without it.'; return 0; }
  printf 'msr\n' > /etc/modules-load.d/meowkit-msr.conf || { warn 'Cannot write MSR module config.'; return 0; }
  printf 'options msr allow_writes=on\n' > /etc/modprobe.d/meowkit-msr.conf || warn 'Cannot write MSR options.'
  if modprobe msr 2>/dev/null; then info 'MSR module loaded where supported.'; else warn 'MSR unavailable/blocked; continuing without MSR tuning.'; fi
}
