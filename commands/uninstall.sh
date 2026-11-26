#!/usr/bin/env bash
set -Eeuo pipefail

systemctl disable --now meowkit-schedule.timer >/dev/null 2>&1 || true
systemctl stop meowkit-schedule.service meowkit-msr.service meowkit.service >/dev/null 2>&1 || true
rm -f /etc/systemd/system/meowkit.service /etc/systemd/system/meowkit-schedule.service \
  /etc/systemd/system/meowkit-schedule.timer /etc/systemd/system/meowkit-msr.service \
  /usr/local/bin/meowkit-xmrig /usr/local/sbin/meowkit-tor-check \
  /usr/local/sbin/meowkit-hugepages /usr/local/sbin/meowkit-schedule \
  /usr/local/sbin/meowkit-msr-enable /etc/modules-load.d/meowkit-msr.conf \
  /etc/modprobe.d/meowkit-msr.conf /etc/systemd/system/meowkit.service.d/10-meowkit-resource-profile.conf
rmdir /etc/systemd/system/meowkit.service.d 2>/dev/null || true
rm -rf /etc/meowkit

# Remove only the exact marker/directive pair that MeowKit manages.
if [[ -f /etc/tor/torrc ]]; then
  tmp=$(mktemp /etc/tor/torrc.meowkit.XXXXXX)
  if awk '
    $0 == "# MeowKit managed SOCKS5 listener" {
      if (getline nextline > 0) {
        if (nextline == "SocksPort 127.0.0.1:9050") { next }
        print
        print nextline
        next
      }
    }
    { print }
  ' /etc/tor/torrc > "$tmp"; then
    chmod --reference=/etc/tor/torrc "$tmp"
    chown --reference=/etc/tor/torrc "$tmp"
    cat "$tmp" > /etc/tor/torrc
  else
    printf 'Warning: could not safely process torrc; it was left unchanged.\n' >&2
  fi
  rm -f "$tmp"
  if command -v tor >/dev/null 2>&1; then
    tor --verify-config -f /etc/tor/torrc >/dev/null 2>&1 || printf 'Warning: Tor configuration needs review after removing the MeowKit listener.\n' >&2
  fi
fi
systemctl daemon-reload
systemctl reset-failed meowkit.service meowkit-schedule.service meowkit-msr.service 2>/dev/null || true
printf 'MeowKit components removed. Tor itself, gateway settings, SSH settings and unrelated services were left intact.\n'
