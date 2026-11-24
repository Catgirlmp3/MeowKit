#!/usr/bin/env bash
set -u
printf 'MeowKit service: '
systemctl is-active --quiet meowkit.service && printf 'active\n' || printf 'inactive\n'
printf 'Enabled at boot: '
systemctl is-enabled --quiet meowkit.service 2>/dev/null && printf 'yes\n' || printf 'no\n'
printf 'Active miner threads: '
pid=$(systemctl show -p MainPID --value meowkit.service 2>/dev/null || echo 0)
if [[ $pid =~ ^[1-9][0-9]*$ && -r /proc/$pid/cmdline ]]; then
  cmd=$(tr '\0' ' ' < "/proc/$pid/cmdline")
  if [[ $cmd =~ --threads=([0-9]+) ]]; then printf '%s (PID %s)\n' "${BASH_REMATCH[1]}" "$pid"; else printf 'unknown (PID %s)\n' "$pid"; fi
else printf 'not running\n'; fi

printf 'Schedule timer: '
systemctl is-active --quiet meowkit-schedule.timer && printf 'active\n' || printf 'inactive\n'
if [[ -r /etc/meowkit/schedule.conf ]]; then
  # Root-owned MeowKit config.
  # shellcheck source=/dev/null
  source /etc/meowkit/schedule.conf
  printf 'Schedule: %s-%s, %s threads, baseline %s, timezone %s\n' "${DAY_START:-?}" "${DAY_END:-?}" "${DAY_THREADS:-?}" "${BASE_THREADS:-?}" "${TIMEZONE:-system local}"
  printf 'Schedule decision: '
  if [[ -x /usr/local/sbin/meowkit-schedule ]]; then
    /usr/local/sbin/meowkit-schedule --dry-run 2>&1 | sed -n '/Time:/p; /Selected threads:/p'
  else printf 'scheduler helper missing\n'; fi
else printf 'Schedule: not configured\n'; fi

printf 'Tor service: '
unit=''
if systemctl show -p LoadState --value tor@default.service 2>/dev/null | grep -qx loaded; then unit='tor@default.service'; fi
if [[ -z $unit ]] && systemctl show -p LoadState --value tor.service 2>/dev/null | grep -qx loaded; then unit='tor.service'; fi
if [[ -n $unit ]] && systemctl is-active --quiet "$unit"; then printf 'active (%s)\n' "$unit"; else printf 'not active\n'; fi
printf 'Tor exit verification: '
if [[ -x /usr/local/sbin/meowkit-tor-check ]] && /usr/local/sbin/meowkit-tor-check >/dev/null 2>&1; then printf 'verified\n'; else printf 'failed/unavailable\n'; fi

for item in '2 MiB:/sys/kernel/mm/hugepages/hugepages-2048kB/nr_hugepages' '1 GiB:/sys/kernel/mm/hugepages/hugepages-1048576kB/nr_hugepages'; do
  name=${item%%:*}; path=${item#*:}
  printf '%s huge pages: ' "$name"
  [[ -r $path ]] && printf '%s reserved\n' "$(cat "$path")" || printf 'unavailable\n'
done
printf 'MSR module: '
if grep -qw msr /proc/modules || [[ -d /sys/module/msr ]]; then
  printf 'loaded; allow_writes='
  [[ -r /sys/module/msr/parameters/allow_writes ]] && cat /sys/module/msr/parameters/allow_writes || printf 'not exposed\n'
else printf 'not loaded\n'; fi
printf 'MSR read probe: '
if command -v rdmsr >/dev/null 2>&1 && rdmsr -p 0 0x10 >/dev/null 2>&1; then printf 'successful\n'; else printf 'failed/unavailable\n'; fi
printf 'Recent miner logs: sudo journalctl -u meowkit.service -n 50 --no-pager\n'
