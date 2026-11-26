#!/usr/bin/env bash
set -Eeuo pipefail
D=${MEOWKIT_DIR:-/etc/meowkit}
CFG=$D/config.json
ENV=$D/runtime.env
SCHED=$D/schedule.conf
SERVICE=meowkit.service
log(){ printf '[MeowKit schedule] %s\n' "$*"; }
fail(){ log "ERROR: $*" >&2; exit 1; }
ACTION=${1:---apply}
case "$ACTION" in --apply|--dry-run) ;; --help|-h) echo "Usage: $0 [--apply|--dry-run]"; exit 0 ;; *) fail "Unknown option: $ACTION";; esac
[[ -r $CFG && -r $ENV && -r $SCHED ]] || fail "MeowKit config/runtime/schedule files are missing."
# Root-owned file maintained by MeowKit.
# shellcheck source=/dev/null
source "$SCHED"
[[ -r $D/resources.conf ]] && { # shellcheck disable=SC1090
  source "$D/resources.conf"
}
if [[ ! ${DAY_PERCENT+x} && ${BASE_THREADS:-0} =~ ^[1-9][0-9]*$ && ${DAY_THREADS:-0} =~ ^[1-9][0-9]*$ ]]; then
  DAY_PERCENT=$((DAY_THREADS * 100 / BASE_THREADS))
  (( DAY_PERCENT > 0 )) || DAY_PERCENT=1
fi
: "${SCHEDULE_ENABLED:=1}" "${DAY_START:=08:00}" "${DAY_END:=16:00}" "${DAY_THREADS:=8}" "${DAY_PERCENT:=40}" "${BASE_THREADS:=1}" "${TOTAL_THREADS:=1}" "${TIMEZONE:=Europe/Dublin}" "${VM_CPU_REDUCTION_PERCENT:=50}"
[[ $SCHEDULE_ENABLED =~ ^[01]$ ]] || fail "SCHEDULE_ENABLED must be 0 or 1."
for t in "$DAY_START" "$DAY_END"; do [[ $t =~ ^([01][0-9]|2[0-3]):[0-5][0-9]$ ]] || fail "Invalid schedule time: $t"; done
[[ $DAY_START != "$DAY_END" ]] || fail "DAY_START and DAY_END must differ."
for n in "$DAY_THREADS" "$BASE_THREADS" "$TOTAL_THREADS"; do [[ $n =~ ^[1-9][0-9]*$ ]] || fail "Invalid thread count: $n"; done
[[ -e /usr/share/zoneinfo/$TIMEZONE ]] || fail "Unknown timezone: $TIMEZONE"
(( BASE_THREADS > TOTAL_THREADS )) && BASE_THREADS=$TOTAL_THREADS
[[ $DAY_PERCENT =~ ^[0-9]+$ ]] && (( DAY_PERCENT >= 1 && DAY_PERCENT <= 100 )) || fail "DAY_PERCENT must be 1-100."
time_min(){ local h=${1%%:*} m=${1##*:}; echo $((10#$h*60+10#$m)); }
NOW=${MEOWKIT_SCHEDULE_NOW:-$(TZ="$TIMEZONE" date +%H:%M)}
[[ $NOW =~ ^([01][0-9]|2[0-3]):[0-5][0-9]$ ]] || fail "Invalid current time: $NOW"
if [[ -n ${MEOWKIT_SCHEDULE_NOW:-} && $ACTION != --dry-run ]]; then fail "MEOWKIT_SCHEDULE_NOW is test-only."; fi
S=$(time_min "$DAY_START"); E=$(time_min "$DAY_END"); N=$(time_min "$NOW")
ACTIVE=0
if [[ $SCHEDULE_ENABLED == 1 ]]; then
  if (( S < E )); then
    if (( N >= S && N < E )); then ACTIVE=1; fi
  else
    if (( N >= S || N < E )); then ACTIVE=1; fi
  fi
fi
DAY_THREADS=$((BASE_THREADS * DAY_PERCENT / 100))
(( DAY_THREADS > 0 )) || DAY_THREADS=1
THREADS=$BASE_THREADS
if (( ACTIVE )); then THREADS=$DAY_THREADS; fi

# Detect both QEMU VMs and LXC containers. The signature changes on guest
# start/stop (and captures IDs); hugepages.sh independently accounts for
# each running guest's configured RAM.
VM_SIGNATURE=''
if command -v qm >/dev/null 2>&1; then
  VM_SIGNATURE+=$(qm list 2>/dev/null | awk 'NR>1 && $3=="running"{print "vm:"$1}' | sort)
fi
if command -v pct >/dev/null 2>&1; then
  VM_SIGNATURE+=$(pct list 2>/dev/null | awk 'NR>1 && $2=="running"{print "ct:"$1}' | sort)
fi
VM_SIGNATURE=${VM_SIGNATURE:-none}
VM_ACTIVE=0
if [[ $VM_SIGNATURE != none ]]; then VM_ACTIVE=1; fi
VM_REDUCTION=0
if (( VM_ACTIVE && VM_CPU_REDUCTION_PERCENT > 0 )); then
  VM_REDUCTION=$VM_CPU_REDUCTION_PERCENT
  THREADS=$((THREADS * (100 - VM_REDUCTION) / 100))
  (( THREADS > 0 )) || THREADS=1
fi
CPU_QUOTA=$((THREADS * 100))
STATE_FILE=$D/vm-state
OLD_VM_SIGNATURE=$(cat "$STATE_FILE" 2>/dev/null || true)
VM_CHANGED=0
if [[ $VM_SIGNATURE != "$OLD_VM_SIGNATURE" ]]; then VM_CHANGED=1; fi
HINT=$(((THREADS*100+TOTAL_THREADS-1)/TOTAL_THREADS))
(( HINT > 100 )) && HINT=100
CURRENT=$(sed -n 's/^MEOWKIT_THREADS=//p' "$ENV" | head -n1)
if [[ $ACTION == --dry-run ]]; then
  printf 'Timezone: %s\nTime: %s\nWindow: %s-%s\nScheduled CPU: %s%%\nRunning guests: %s\nVM CPU reduction: %s%%\nSelected threads: %s\nCurrent threads: %s\n' "$TIMEZONE" "$NOW" "$DAY_START" "$DAY_END" "$DAY_PERCENT" "$VM_SIGNATURE" "$VM_REDUCTION" "$THREADS" "${CURRENT:-unknown}"
  exit 0
fi
[[ $EUID -eq 0 ]] || fail "Run as root."
command -v flock >/dev/null || fail "flock is required."
exec 9>"$D/.schedule.lock"; flock -n 9 || exit 0
is_running_with(){
  local pid cmd
  systemctl is-active --quiet "$SERVICE" || return 1
  pid=$(systemctl show -p MainPID --value "$SERVICE" 2>/dev/null || echo 0)
  [[ $pid =~ ^[1-9][0-9]*$ && -r /proc/$pid/cmdline ]] || return 1
  cmd=$(tr '\0' ' ' < /proc/$pid/cmdline)
  [[ $cmd == *"--threads=$1"* ]]
}
FORCE=${MEOWKIT_FORCE_RESTART:-0}
if [[ $CURRENT == "$THREADS" ]] && (( FORCE == 0 && VM_CHANGED == 0 )) && is_running_with "$THREADS"; then
  log "Already running with $THREADS threads; no restart needed."
  exit 0
fi
exec 8>"$D/.config.lock"; flock -x 8
TMP=$(mktemp -d "$D/.schedule.XXXXXX"); trap 'rm -rf -- "$TMP"' EXIT
cp -a "$CFG" "$TMP/config.old"; cp -a "$ENV" "$TMP/runtime.old"
DROPIN_DIR=/etc/systemd/system/meowkit.service.d
DROPIN=$DROPIN_DIR/10-meowkit-resource-profile.conf
mkdir -p "$DROPIN_DIR"
if [[ -e $DROPIN ]]; then cp -a "$DROPIN" "$TMP/dropin.old"; else : > "$TMP/dropin.absent"; fi
cat > "$TMP/dropin.new" <<EOFPROFILE
[Service]
CPUQuota=${CPU_QUOTA}%
EOFPROFILE
python3 - "$CFG" "$TMP/config.new" "$HINT" <<'PY'
import json, os, sys
src, dst, hint = sys.argv[1], sys.argv[2], int(sys.argv[3])
with open(src, encoding="utf-8") as f: data=json.load(f)
data.setdefault("cpu", {})["max-threads-hint"] = hint
data["autosave"] = False
with open(dst, "w", encoding="utf-8") as f: json.dump(data, f, indent=2); f.write("\n")
os.chmod(dst, 0o640)
PY
python3 -m json.tool "$TMP/config.new" >/dev/null || fail "Staged JSON is invalid."
printf 'MEOWKIT_THREADS=%s\n' "$THREADS" > "$TMP/runtime.new"; chmod 640 "$TMP/runtime.new"
mv -f "$TMP/config.new" "$CFG"; mv -f "$TMP/runtime.new" "$ENV"
install -m 0644 "$TMP/dropin.new" "$DROPIN"
flock -u 8; exec 8>&-
if (( VM_CHANGED )); then
  log "Proxmox guest state changed; stopping miner before recalculating huge pages."
  systemctl stop "$SERVICE" || fail "Could not stop miner safely for VM resource transition."
  if [[ -x /usr/local/sbin/meowkit-hugepages ]]; then
    /usr/local/sbin/meowkit-hugepages || log "Huge-page recalculation returned a warning; continuing with available pages."
  fi
fi
if ! systemctl daemon-reload; then
  cp -a "$TMP/config.old" "$CFG"; cp -a "$TMP/runtime.old" "$ENV"
  [[ -f "$TMP/dropin.old" ]] && cp -a "$TMP/dropin.old" "$DROPIN" || rm -f "$DROPIN"
  fail "daemon-reload failed; config and resource profile rolled back."
fi
[[ -x /usr/local/sbin/meowkit-msr-enable ]] && /usr/local/sbin/meowkit-msr-enable || true
restart_verify(){
  local expected=$1 tries=$2 attempt tick pid cmd newpid
  local -a pause=(3 8 15)
  for ((attempt=1; attempt<=tries; attempt++)); do
    log "Restart attempt $attempt/$tries for $expected threads."
    systemctl restart "$SERVICE" || true
    for ((tick=0; tick<40; tick++)); do
      if systemctl is-active --quiet "$SERVICE"; then
        pid=$(systemctl show -p MainPID --value "$SERVICE" 2>/dev/null || echo 0)
        if [[ $pid =~ ^[1-9][0-9]*$ && -r /proc/$pid/cmdline ]]; then
          cmd=$(tr '\0' ' ' < /proc/$pid/cmdline)
          if [[ $cmd == *"--threads=$expected"* ]]; then
            sleep 2; newpid=$(systemctl show -p MainPID --value "$SERVICE" 2>/dev/null || echo 0)
            [[ $newpid == "$pid" ]] && systemctl is-active --quiet "$SERVICE" && { log "Verified PID $pid with --threads=$expected."; return 0; }
          fi
        fi
      fi
      sleep 1
    done
    journalctl -u "$SERVICE" -n 20 --no-pager 2>/dev/null || true
    (( attempt < tries )) && sleep "${pause[$((attempt-1))]}"
  done
  return 1
}
if restart_verify "$THREADS" 3; then
  printf '%s\n' "$VM_SIGNATURE" > "$STATE_FILE"
  log "Schedule/resource profile applied: $THREADS threads, CPUQuota=${CPU_QUOTA}%, VM active=$VM_ACTIVE."
  exit 0
fi
log "New start failed; rolling configuration back."
exec 8>"$D/.config.lock"; flock -x 8
cp -a "$TMP/config.old" "$CFG"; cp -a "$TMP/runtime.old" "$ENV"
[[ -f "$TMP/dropin.old" ]] && cp -a "$TMP/dropin.old" "$DROPIN" || rm -f "$DROPIN"
flock -u 8; exec 8>&-
systemctl daemon-reload || true
OLD=$(sed -n 's/^MEOWKIT_THREADS=//p' "$ENV" | head -n1)
if [[ $OLD =~ ^[1-9][0-9]*$ ]] && restart_verify "$OLD" 2; then
  log "Rollback successful ($OLD threads); timer will retry the scheduled value next minute."
else
  log "CRITICAL: rollback restart failed. systemd Restart=always and the schedule timer will retry."
fi
exit 1
