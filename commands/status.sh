#!/usr/bin/env bash
set -u
printf 'MeowKit service: '
systemctl is-active --quiet meowkit.service && printf 'active\n' || printf 'inactive\n'
printf 'Enabled at boot: '
systemctl is-enabled --quiet meowkit.service 2>/dev/null && printf 'yes\n' || printf 'no\n'
printf 'Tor service: '
unit=''
if systemctl show -p LoadState --value tor@default.service 2>/dev/null | grep -qx loaded; then unit='tor@default.service'; fi
if [[ -z "$unit" ]] && systemctl show -p LoadState --value tor.service 2>/dev/null | grep -qx loaded; then unit='tor.service'; fi
if [[ -n "$unit" ]] && systemctl is-active --quiet "$unit"; then printf 'active (%s)\n' "$unit"; else printf 'not active\n'; fi
printf 'Tor exit verification: '
if [[ -x /usr/local/sbin/meowkit-tor-check ]] && /usr/local/sbin/meowkit-tor-check >/dev/null 2>&1; then
  printf 'verified (Tor Project IsTor=true)\n'
else
  printf 'failed or unavailable\n'
fi
printf '2 MiB huge pages: '
hp='/sys/kernel/mm/hugepages/hugepages-2048kB/nr_hugepages'
if [[ -r $hp ]]; then printf '%s pages reserved\n' "$(cat "$hp")"; else printf 'unavailable\n'; fi
printf '1 GiB huge pages: '
hp1='/sys/kernel/mm/hugepages/hugepages-1048576kB/nr_hugepages'
if [[ -r $hp1 ]]; then printf '%s pages reserved\n' "$(cat "$hp1")"; else printf 'unavailable\n'; fi
printf 'MSR module: '
grep -qw msr /proc/modules && printf 'loaded\n' || printf 'not loaded\n'
printf 'Active miner threads: '
if [[ -r /etc/meowkit/runtime.env ]]; then
  source /etc/meowkit/runtime.env
  printf '%s\n' "${MEOWKIT_THREADS:-unknown}"
else printf 'unknown\n'; fi
if [[ -r /etc/meowkit/resource-profile.conf ]]; then
  # Root-owned MeowKit profile.
  source /etc/meowkit/resource-profile.conf
  printf 'Baseline CPU: %s%% (%s/%s threads)\n' "${CPU_PERCENT:-?}" "${BASE_THREADS:-?}" "${TOTAL_THREADS:-?}"
  printf 'Huge-page RAM budget: %s%%\n' "${RAM_PERCENT:-?}"
  printf 'VM CPU reduction: %s%%\n' "${VM_CPU_REDUCTION_PERCENT:-?}"
  printf 'Schedule: %s, %s-%s at %s%% of baseline (%s)\n' "${SCHEDULE_ENABLED:-?}" "${DAY_START:-?}" "${DAY_END:-?}" "${DAY_PERCENT:-?}" "${TIMEZONE:-?}"
fi
printf 'Adaptive resource timer: '
systemctl is-active --quiet meowkit-resource-watch.timer && printf 'active\n' || printf 'inactive\n'
if [[ -x /usr/local/sbin/meowkit-resource-watch ]]; then
  /usr/local/sbin/meowkit-resource-watch --dry-run 2>/dev/null | sed -n '/Running guests:/p; /Selected threads:/p; /CPUQuota:/p'
fi
printf 'Application log files: none created by MeowKit\n'
