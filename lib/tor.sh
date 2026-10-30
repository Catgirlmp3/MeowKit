#!/usr/bin/env bash
bootstrap_tor() {
  begin_step 'Tor bootstrap'
  export DEBIAN_FRONTEND=noninteractive
  if ! command -v tor >/dev/null 2>&1; then
    info 'Tor is not installed. Installing Tor and required tools (initial package bootstrap).'
    apt-get update -qq || fail 'Package index update failed during initial Tor bootstrap.'
    apt-get install -y -qq tor curl ca-certificates python3 tar gzip || fail 'Could not install Tor and required packages.'
  else
    for pkg in curl python3 tar; do
      command -v "$pkg" >/dev/null 2>&1 || fail "Required tool '$pkg' is missing. Install it before running MeowKit; refusing an unproxied package download."
    done
  fi

  install -d -m 755 /etc/tor
  local torrc='/etc/tor/torrc'
  [[ -f $torrc ]] || touch "$torrc"
  local backup="$torrc.meowkit-backup.$(date +%Y%m%d%H%M%S)"
  cp -a "$torrc" "$backup" || fail 'Could not back up the existing Tor configuration.'
  if ! grep -Eq '^[[:space:]]*SocksPort[[:space:]]+127\.0\.0\.1:9050([[:space:]]|$)' "$torrc"; then
    printf '\n# MeowKit managed SOCKS5 listener\nSocksPort 127.0.0.1:9050\n' >> "$torrc"
  fi
  if ! tor --verify-config -f "$torrc" >/dev/null 2>&1; then
    cp -a "$backup" "$torrc" || printf 'Warning: automatic Tor configuration rollback failed; backup: %s\n' "$backup" >&2
    fail 'Tor configuration validation failed. The previous configuration was restored where possible.'
  fi

  # Prefer the instance unit when both units are installed.
  if systemctl list-unit-files tor@default.service --no-legend 2>/dev/null | grep -q '^tor@default\.service'; then
    TOR_UNIT='tor@default.service'
  elif systemctl list-unit-files tor.service --no-legend 2>/dev/null | grep -q '^tor\.service'; then
    TOR_UNIT='tor.service'
  else
    fail 'No supported Tor systemd unit was found.'
  fi
  systemctl enable "$TOR_UNIT" >/dev/null 2>&1 || fail "Could not enable $TOR_UNIT at boot."
  systemctl restart "$TOR_UNIT" || fail "Could not start/restart $TOR_UNIT."

  local ok=0
  for _ in {1..18}; do
    if curl --connect-timeout 5 --max-time 12 --silent --fail --socks5-hostname 127.0.0.1:9050 https://check.torproject.org/api/ip >/dev/null 2>&1; then ok=1; break; fi
    sleep 5
  done
  ((ok == 1)) || fail 'Tor did not establish a working SOCKS5 connection within 90 seconds. Check relay reachability, clock and firewall.'
  info 'Tor is running and SOCKS5 connectivity is verified.'
}

curl_tor() {
  curl --fail --location --silent --show-error --connect-timeout 20 --max-time 300 --socks5-hostname 127.0.0.1:9050 "$@"
}
