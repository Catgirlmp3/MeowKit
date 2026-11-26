#!/usr/bin/env bash
set -Eeuo pipefail
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
TMP=$(mktemp -d); trap 'rm -rf -- "$TMP"' EXIT
D=$TMP/meowkit; mkdir -p "$D" "$TMP/bin"
cat > "$D/resource-profile.conf" <<'EOFPROFILE'
BASE_THREADS=16
TOTAL_THREADS=16
CPU_PERCENT=100
RAM_PERCENT=75
VM_CPU_REDUCTION_PERCENT=50
SCHEDULE_ENABLED=1
DAY_START=08:00
DAY_END=16:00
DAY_PERCENT=40
TIMEZONE=UTC
EOFPROFILE
cat > "$TMP/bin/qm" <<'EOFQM'
#!/usr/bin/env bash
printf ' VMID NAME STATUS\n 100 test running\n'
EOFQM
chmod +x "$TMP/bin/qm"
out=$(MEOWKIT_DIR="$D" PATH="$TMP/bin:$PATH" MEOWKIT_RESOURCE_NOW=12:00 bash "$ROOT/commands/resource-watch.sh" --dry-run)
grep -Fq 'Schedule active: 1' <<<"$out"
grep -Fq 'Running guests: vm:100' <<<"$out"
grep -Fq 'VM reduction: 50%' <<<"$out"
grep -Fq 'Selected threads: 3' <<<"$out"
grep -Fq 'CPUQuota: 300%' <<<"$out"
printf 'PASS scheduled 40%% baseline plus 50%% VM reduction -> 3/16 threads\n'

out=$(MEOWKIT_DIR="$D" PATH="$TMP/bin:$PATH" MEOWKIT_RESOURCE_NOW=17:00 bash "$ROOT/commands/resource-watch.sh" --dry-run)
grep -Fq 'Selected threads: 8' <<<"$out"
printf 'PASS outside schedule with VM active -> 8/16 threads\n'

cat > "$TMP/bin/qm" <<'EOFQM'
#!/usr/bin/env bash
printf ' VMID NAME STATUS\n 100 test stopped\n'
EOFQM
chmod +x "$TMP/bin/qm"
out=$(MEOWKIT_DIR="$D" PATH="$TMP/bin:$PATH" MEOWKIT_RESOURCE_NOW=12:00 bash "$ROOT/commands/resource-watch.sh" --dry-run)
grep -Fq 'Running guests: none' <<<"$out"
grep -Fq 'VM reduction: 0%' <<<"$out"
grep -Fq 'Selected threads: 6' <<<"$out"
printf 'PASS guest stopped -> scheduled allocation restored to 6/16 threads\n'

# Initial preparation must persist the final profile without touching service state.
mkdir -p "$TMP/systemd"
cat > "$TMP/bin/systemctl" <<'EOFSYSTEMCTL'
#!/usr/bin/env bash
printf '%s\\n' "$*" >> "$MEOWKIT_SYSTEMCTL_LOG"
case "$1" in
  daemon-reload) exit 0 ;;
  is-active) exit 1 ;;
  *) exit 0 ;;
esac
EOFSYSTEMCTL
chmod +x "$TMP/bin/systemctl"
cat > "$TMP/bin/qm" <<'EOFQM'
#!/usr/bin/env bash
printf ' VMID NAME STATUS\n 100 test running\n'
EOFQM
chmod +x "$TMP/bin/qm"
sed -i 's/^SCHEDULE_ENABLED=1$/SCHEDULE_ENABLED=0/' "$D/resource-profile.conf"
rm -f "$D/runtime.env" "$D/resource-state"
: > "$TMP/systemctl.log"
if [[ $EUID -eq 0 ]]; then
  out=$(MEOWKIT_DIR="$D" MEOWKIT_SYSTEMD_DIR="$TMP/systemd" MEOWKIT_SYSTEMCTL_LOG="$TMP/systemctl.log" PATH="$TMP/bin:$PATH" bash "$ROOT/commands/resource-watch.sh" --prepare)
else
  out=$(sudo env "MEOWKIT_DIR=$D" "MEOWKIT_SYSTEMD_DIR=$TMP/systemd" "MEOWKIT_SYSTEMCTL_LOG=$TMP/systemctl.log" "PATH=$TMP/bin:$PATH" bash "$ROOT/commands/resource-watch.sh" --prepare)
fi
if [[ $EUID -ne 0 ]]; then sudo chown -R "$(id -u):$(id -g)" "$TMP"; fi
grep -Fq 'Prepared initial profile: 8 threads' <<<"$out"
grep -Fqx 'MEOWKIT_THREADS=8' "$D/runtime.env"
grep -Fqx 'THREADS=8' "$D/resource-state"
grep -Fqx 'CPUQuota=800%' "$TMP/systemd/meowkit.service.d/10-meowkit-resource-profile.conf"
! grep -Eq '^(start|stop|restart) ' "$TMP/systemctl.log"
printf 'PASS initial preparation persists final guest/schedule profile without service restart\\n'
