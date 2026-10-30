#!/usr/bin/env bash
set -u
printf 'MeowKit service: '
systemctl is-active --quiet meowkit.service && printf 'active\n' || printf 'inactive\n'
printf 'Enabled at boot: '
systemctl is-enabled --quiet meowkit.service 2>/dev/null && printf 'yes\n' || printf 'no\n'
printf 'Tor service: '
unit=""
if systemctl show -p LoadState --value tor@default.service 2>/dev/null | grep -qx loaded; then unit="tor@default.service"; fi
if [[ -z "$unit" ]] && systemctl show -p LoadState --value tor.service 2>/dev/null | grep -qx loaded; then unit="tor.service"; fi
if [[ -n "$unit" ]] && systemctl is-active --quiet "$unit"; then printf 'active (%s)\n' "$unit"; else printf 'not active\n'; fi
printf 'SOCKS5 route: '
if command -v curl >/dev/null 2>&1 && curl --connect-timeout 8 --max-time 15 --silent --fail \
  --socks5-hostname 127.0.0.1:9050 https://check.torproject.org/api/ip >/dev/null 2>&1; then
  printf 'reachable through Tor\n'
else
  printf 'unavailable\n'
fi
printf 'Application log files: none created by MeowKit\n'
