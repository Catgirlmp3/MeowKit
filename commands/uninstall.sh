#!/usr/bin/env bash
set -Eeuo pipefail

systemctl disable --now meowkit.service >/dev/null 2>&1 || true
rm -f /etc/systemd/system/meowkit.service /usr/local/bin/meowkit-xmrig /usr/local/sbin/meowkit-tor-check
rm -rf /etc/meowkit

# Remove the listener only when the exact managed marker is immediately
# followed by the exact directive MeowKit writes. Never delete an arbitrary
# following line if an administrator has edited torrc since installation.
if [[ -f /etc/tor/torrc ]]; then
  tmp=$(mktemp /etc/tor/torrc.meowkit.XXXXXX)
  if awk '
    $0 == "# MeowKit managed SOCKS5 listener" {
      if (getline nextline > 0) {
        if (nextline == "SocksPort 127.0.0.1:9050") {
          next
        }
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
printf 'MeowKit components removed. Tor itself, gateway settings, SSH settings and unrelated services were left intact.\n'
