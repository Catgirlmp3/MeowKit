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
: "${SCHEDULE_ENABLED:=1}" "${DAY_START:=08:00}" "${DAY_END:=16:00}" "${DAY_THREADS:=8}" "${BASE_THREADS:=1}" "${TOTAL_THREADS:=1}" "${TIMEZONE:=Europe/Dublin}"
[[ $SCHEDULE_ENABLED =~ ^[01]$ ]] || fail "SCHEDULE_ENABLED must be 0 or 1."
for t in "$DAY_START" "$DAY_END"; do [[ $t =~ ^([01][0-9]|2[0-3]):[0-5][0-9]$ ]] || fail "Invalid schedule time: $t"; done
[[ $DAY_START != "$DAY_END" ]] || fail "DAY_START and DAY_END must differ."
for n in "$DAY_THREADS" "$BASE_THREADS" "$TOTAL_THREADS"; do [[ $n =~ ^[1-9][0-9]*$ ]] || fail "Invalid thread count: $n"; done
[[ -e /usr/share/zoneinfo/$TIMEZONE ]] || fail "Unknown timezone: $TIMEZONE"
(( BASE_THREADS > TOTAL_THREADS )) && BASE_THREADS=$TOTAL_THREADS
(( DAY_THREADS > BASE_THREADS )) && DAY_THREADS=$BASE_THREADS
time_min(){ local h=${1%%:*} m=${1##*:}; echo $((10#$h*60+10#$m)); }
NOW=${MEOWKIT_SCHEDULE_NOW:-$(TZ="$TIMEZONE" date +%H:%M)}
[[ $NOW =~ ^([01][0-9]|2[0-3]):[0-5][0-9]$ ]] || fail "Invalid current time: $NOW"
if [[ -n ${MEOWKIT_SCHEDULE_NOW:-} && $ACTION != --dry-run ]]; then fail "MEOWKIT_SCHEDULE_NOW is test-only."; fi
S=$(time_min "$DAY_START"); E=$(time_min "$DAY_END"); N=$(time_min "$NOW")
ACTIVE=0
if [[ $SCHEDULE_ENABLED == 1 ]]; then
  if (( S < E )); then (( N >= S && N < E )) && ACTIVE=1
  else (( N >= S || N < E )) && ACTIVE=1
  fi
fi
THREADS=$BASE_THREADS
(( ACTIVE )) && THREADS=$DAY_THREADS
HINT=$(((THREADS*100+TOTAL_THREADS-1)/TOTAL_THREADS))
(( HINT > 100 )) && HINT=100
CURRENT=$(sed -n 's/^MEOWKIT_THREADS=//p' "$ENV" | head -n1)
if [[ $ACTION == --dry-run ]]; then
  printf 'Timezone: %s\nTime: %s\nWindow: %s-%s\nSelected threads: %s\nCurrent threads: %s\n' "$TIMEZONE" "$NOW" "$DAY_START" "$DAY_END" "$THREADS" "${CURRENT:-unknown}"
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
if [[ $CURRENT == "$THREADS" ]] && (( FORCE == 0 )) && is_running_with "$THREADS"; then
  log "Already running with $THREADS threads; no restart needed."
  exit 0
fi
exec 8>"$D/.config.lock"; flock -x 8
TMP=$(mktemp -d "$D/.schedule.XXXXXX"); trap 'rm -rf -- "$TMP"' EXIT
cp -a "$CFG" "$TMP/config.old"; cp -a "$ENV" "$TMP/runtime.old"
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
flock -u 8; exec 8>&-
if ! systemctl daemon-reload; then cp -a "$TMP/config.old" "$CFG"; cp -a "$TMP/runtime.old" "$ENV"; fail "daemon-reload failed; config rolled back."; fi
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
if restart_verify "$THREADS" 3; then log "Schedule applied: $THREADS threads."; exit 0; fi
log "New start failed; rolling configuration back."
exec 8>"$D/.config.lock"; flock -x 8
cp -a "$TMP/config.old" "$CFG"; cp -a "$TMP/runtime.old" "$ENV"
flock -u 8; exec 8>&-
systemctl daemon-reload || true
OLD=$(sed -n 's/^MEOWKIT_THREADS=//p' "$ENV" | head -n1)
if [[ $OLD =~ ^[1-9][0-9]*$ ]] && restart_verify "$OLD" 2; then
  log "Rollback successful ($OLD threads); timer will retry the scheduled value next minute."
else
  log "CRITICAL: rollback restart failed. systemd Restart=always and the schedule timer will retry."
fi
exit 1
