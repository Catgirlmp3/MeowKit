#!/usr/bin/env bash
set -Eeuo pipefail
D=${MEOWKIT_DIR:-/etc/meowkit}
PROFILE=$D/resource-profile.conf
RUNTIME=$D/runtime.env
SERVICE=meowkit.service
ACTION=${1:---apply}
case "$ACTION" in --apply|--dry-run) ;; *) echo "Usage: $0 [--apply|--dry-run]" >&2; exit 2 ;; esac
[[ -r $PROFILE ]] || { echo "[MeowKit resource] Missing $PROFILE" >&2; exit 1; }
# Root-owned profile written by the installer.
source "$PROFILE"
: "${BASE_THREADS:=1}" "${TOTAL_THREADS:=1}" "${VM_CPU_REDUCTION_PERCENT:=50}" "${SCHEDULE_ENABLED:=1}" "${DAY_START:=08:00}" "${DAY_END:=16:00}" "${DAY_PERCENT:=40}" "${TIMEZONE:=Europe/Dublin}" "${RAM_PERCENT:=75}"
for n in "$BASE_THREADS" "$TOTAL_THREADS" "$VM_CPU_REDUCTION_PERCENT" "$DAY_PERCENT" "$RAM_PERCENT"; do
  [[ $n =~ ^[0-9]+$ ]] || { echo '[MeowKit resource] Invalid numeric profile value.' >&2; exit 1; }
done
(( BASE_THREADS >= 1 && BASE_THREADS <= TOTAL_THREADS )) || { echo '[MeowKit resource] Invalid baseline thread count.' >&2; exit 1; }
(( VM_CPU_REDUCTION_PERCENT <= 90 && DAY_PERCENT >= 1 && DAY_PERCENT <= 100 && RAM_PERCENT >= 1 && RAM_PERCENT <= 100 )) || { echo '[MeowKit resource] Profile percentage out of range.' >&2; exit 1; }
[[ $SCHEDULE_ENABLED == 0 || $SCHEDULE_ENABLED == 1 ]] || { echo '[MeowKit resource] Invalid schedule toggle.' >&2; exit 1; }
[[ $DAY_START =~ ^([01][0-9]|2[0-3]):[0-5][0-9]$ && $DAY_END =~ ^([01][0-9]|2[0-3]):[0-5][0-9]$ && $DAY_START != "$DAY_END" ]] || { echo '[MeowKit resource] Invalid schedule window.' >&2; exit 1; }
[[ -e /usr/share/zoneinfo/$TIMEZONE ]] || { echo "[MeowKit resource] Unknown timezone $TIMEZONE." >&2; exit 1; }

minute(){ local h=${1%%:*} m=${1##*:}; echo $((10#$h*60+10#$m)); }
NOW=${MEOWKIT_RESOURCE_NOW:-$(TZ="$TIMEZONE" date +%H:%M)}
[[ $NOW =~ ^([01][0-9]|2[0-3]):[0-5][0-9]$ ]] || { echo '[MeowKit resource] Invalid current time.' >&2; exit 1; }
if [[ -n ${MEOWKIT_RESOURCE_NOW:-} && $ACTION != --dry-run ]]; then echo 'MEOWKIT_RESOURCE_NOW is test-only.' >&2; exit 1; fi
S=$(minute "$DAY_START"); E=$(minute "$DAY_END"); N=$(minute "$NOW")
SCHEDULE_ACTIVE=0
if (( SCHEDULE_ENABLED )); then
  if (( S < E )); then
    if (( N >= S && N < E )); then SCHEDULE_ACTIVE=1; fi
  else
    if (( N >= S || N < E )); then SCHEDULE_ACTIVE=1; fi
  fi
fi
THREADS=$BASE_THREADS
if (( SCHEDULE_ACTIVE )); then
  THREADS=$((BASE_THREADS * DAY_PERCENT / 100))
  (( THREADS > 0 )) || THREADS=1
fi

VM_SIGNATURE=''
if command -v qm >/dev/null 2>&1; then
  QM_OUTPUT=$(qm list 2>/dev/null) || { echo '[MeowKit resource] qm list failed; refusing to guess guest state.' >&2; exit 1; }
  VM_SIGNATURE+=$(awk 'NR>1 && $3=="running"{print "vm:"$1}' <<<"$QM_OUTPUT" | sort)
fi
if command -v pct >/dev/null 2>&1; then
  PCT_OUTPUT=$(pct list 2>/dev/null) || { echo '[MeowKit resource] pct list failed; refusing to guess guest state.' >&2; exit 1; }
  VM_SIGNATURE+=$(awk 'NR>1 && $2=="running"{print "ct:"$1}' <<<"$PCT_OUTPUT" | sort)
fi
VM_SIGNATURE=${VM_SIGNATURE:-none}
VM_ACTIVE=0
[[ $VM_SIGNATURE != none ]] && VM_ACTIVE=1
VM_REDUCTION=0
if (( VM_ACTIVE && VM_CPU_REDUCTION_PERCENT > 0 )); then
  VM_REDUCTION=$VM_CPU_REDUCTION_PERCENT
  THREADS=$((THREADS * (100 - VM_REDUCTION) / 100))
  (( THREADS > 0 )) || THREADS=1
fi
CPU_QUOTA=$((THREADS * 100))
CURRENT=$(sed -n 's/^MEOWKIT_THREADS=//p' "$RUNTIME" 2>/dev/null | head -n1 || true)
STATE=$D/resource-state
OLD_SIGNATURE=$(sed -n 's/^VM_SIGNATURE=//p' "$STATE" 2>/dev/null | head -n1 || true)
DROPIN=/etc/systemd/system/meowkit.service.d/10-meowkit-resource-profile.conf
if [[ $ACTION == --dry-run ]]; then
  printf 'Time: %s (%s)\nSchedule active: %s (%s-%s at %s%% of baseline)\nRunning guests: %s\nVM reduction: %s%%\nSelected threads: %s\nCPUQuota: %s%%\nCurrent threads: %s\n' "$NOW" "$TIMEZONE" "$SCHEDULE_ACTIVE" "$DAY_START" "$DAY_END" "$DAY_PERCENT" "$VM_SIGNATURE" "$VM_REDUCTION" "$THREADS" "$CPU_QUOTA" "${CURRENT:-unknown}"
  exit 0
fi
[[ $EUID -eq 0 ]] || { echo 'Run as root.' >&2; exit 1; }
# A timer tick must never resurrect a miner that an operator intentionally stopped.
if ! systemctl is-active --quiet "$SERVICE"; then
  echo '[MeowKit resource] Miner is not active; leaving it stopped.'
  exit 0
fi
command -v flock >/dev/null || { echo 'flock is required.' >&2; exit 1; }
exec 9>"$D/.resource-watch.lock"; flock -n 9 || exit 0
if [[ $CURRENT == "$THREADS" && $OLD_SIGNATURE == "$VM_SIGNATURE" && -f $DROPIN ]] &&
   grep -qxF "CPUQuota=${CPU_QUOTA}%" "$DROPIN" && systemctl is-active --quiet "$SERVICE"; then
  exit 0
fi

mkdir -p "$(dirname "$DROPIN")"
TMP=$(mktemp -d "$D/.resource.XXXXXX")
trap 'rm -rf -- "$TMP"' EXIT
[[ -f $RUNTIME ]] && cp -a "$RUNTIME" "$TMP/runtime.old" || : > "$TMP/runtime.absent"
[[ -f $DROPIN ]] && cp -a "$DROPIN" "$TMP/dropin.old" || : > "$TMP/dropin.absent"
[[ -f $D/hugepages.conf ]] && cp -a "$D/hugepages.conf" "$TMP/hugepages.old" || : > "$TMP/hugepages.absent"

restore_previous() {
  [[ -f "$TMP/runtime.old" ]] && cp -a "$TMP/runtime.old" "$RUNTIME" || rm -f "$RUNTIME"
  [[ -f "$TMP/dropin.old" ]] && cp -a "$TMP/dropin.old" "$DROPIN" || rm -f "$DROPIN"
  [[ -f "$TMP/hugepages.old" ]] && cp -a "$TMP/hugepages.old" "$D/hugepages.conf" || rm -f "$D/hugepages.conf"
  systemctl daemon-reload || true
  [[ -x /usr/local/sbin/meowkit-hugepages ]] && /usr/local/sbin/meowkit-hugepages || true
  systemctl restart "$SERVICE" || true
}

echo "[MeowKit resource] Applying $THREADS threads; VM signature=$VM_SIGNATURE; CPUQuota=${CPU_QUOTA}%."
systemctl stop "$SERVICE"
printf 'MEOWKIT_THREADS=%s\n' "$THREADS" > "$TMP/runtime.new"
chmod 640 "$TMP/runtime.new"
install -m 0644 "$TMP/runtime.new" "$RUNTIME"
cat > "$TMP/dropin.new" <<EOFPROFILE
[Service]
CPUQuota=${CPU_QUOTA}%
EOFPROFILE
install -m 0644 "$TMP/dropin.new" "$DROPIN"
cat > "$D/hugepages.conf" <<EOFHP
RAM_PERCENT=$RAM_PERCENT
THREADS=$THREADS
HOST_RESERVE_MB=2048
EOFHP
if [[ -x /usr/local/sbin/meowkit-hugepages ]]; then
  /usr/local/sbin/meowkit-hugepages || echo '[MeowKit resource] Huge-page recalculation returned a warning; continuing.' >&2
fi
if ! systemctl daemon-reload; then
  echo '[MeowKit resource] systemd daemon-reload failed; restoring previous profile.' >&2
  restore_previous
  exit 1
fi

restart_and_verify(){
  local attempt pid cmd tick
  for attempt in 1 2 3; do
    systemctl restart "$SERVICE" || true
    for ((tick=0; tick<45; tick++)); do
      if systemctl is-active --quiet "$SERVICE"; then
        pid=$(systemctl show -p MainPID --value "$SERVICE" 2>/dev/null || echo 0)
        if [[ $pid =~ ^[1-9][0-9]*$ && -r /proc/$pid/cmdline ]]; then
          cmd=$(tr '\0' ' ' < "/proc/$pid/cmdline")
          if [[ $cmd == *"--threads=$THREADS"* ]]; then return 0; fi
        fi
      fi
      sleep 1
    done
    journalctl -u "$SERVICE" -n 20 --no-pager 2>/dev/null || true
  done
  return 1
}
if restart_and_verify; then
  printf 'VM_SIGNATURE=%s\nTHREADS=%s\nCPU_QUOTA=%s\n' "$VM_SIGNATURE" "$THREADS" "$CPU_QUOTA" > "$STATE"
  chmod 600 "$STATE"
  echo "[MeowKit resource] Verified miner running with $THREADS threads."
  exit 0
fi

echo '[MeowKit resource] New profile failed; restoring the previous settings.' >&2
restore_previous
exit 1
