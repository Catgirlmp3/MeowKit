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
printf 'Application log files: none created by MeowKit\n'
