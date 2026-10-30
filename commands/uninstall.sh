#!/usr/bin/env bash
set -Eeuo pipefail

systemctl disable --now meowkit.service >/dev/null 2>&1 || true
rm -f /etc/systemd/system/meowkit.service /usr/local/bin/meowkit-xmrig /usr/local/sbin/meowkit-tor-check
rm -rf /etc/meowkit

# Remove only MeowKit's Tor listener stanza. Preserve all unrelated Tor settings.
if [[ -f /etc/tor/torrc ]]; then
  sed -i '/^# MeowKit managed SOCKS5 listener$/,+1d' /etc/tor/torrc
  if command -v tor >/dev/null 2>&1; then
    tor --verify-config -f /etc/tor/torrc >/dev/null 2>&1 || printf 'Warning: Tor configuration needs review after removing the MeowKit listener.\n' >&2
  fi
fi

systemctl daemon-reload
printf 'MeowKit components removed. Tor itself, gateway settings, SSH settings and unrelated services were left intact.\n'
