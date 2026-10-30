#!/usr/bin/env bash
bootstrap_tor() {
  begin_step 'Tor bootstrap'
  export DEBIAN_FRONTEND=noninteractive

  # Repair missing runtime tools even when Tor was installed beforehand.
  local missing=()
  command -v tor >/dev/null 2>&1 || missing+=(tor)
  command -v curl >/dev/null 2>&1 || missing+=(curl)
  command -v python3 >/dev/null 2>&1 || missing+=(python3)
  command -v tar >/dev/null 2>&1 || missing+=(tar)
  command -v gzip >/dev/null 2>&1 || missing+=(gzip)
  [[ -s /etc/ssl/certs/ca-certificates.crt ]] || missing+=(ca-certificates)
  if (("${#missing[@]}" > 0)); then
    info "Installing missing prerequisites: ${missing[*]}"
    apt-get update -qq || fail 'Package index update failed during prerequisite installation.'
    apt-get install -y -qq "${missing[@]}" || fail 'Could not install Tor and required packages.'
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

  if systemctl list-unit-files tor@default.service --no-legend 2>/dev/null | grep -q '^tor@default\.service'; then
    TOR_UNIT='tor@default.service'
  elif systemctl list-unit-files tor.service --no-legend 2>/dev/null | grep -q '^tor\.service'; then
    TOR_UNIT='tor.service'
  else
    fail 'No supported Tor systemd unit was found.'
  fi
  systemctl enable "$TOR_UNIT" >/dev/null 2>&1 || fail "Could not enable $TOR_UNIT at boot."
  systemctl restart "$TOR_UNIT" || fail "Could not start/restart $TOR_UNIT."

  local ok=0 response
  for _ in {1..18}; do
    if response=$(curl --connect-timeout 5 --max-time 12 --silent --fail --socks5-hostname 127.0.0.1:9050 https://check.torproject.org/api/ip 2>/dev/null) &&
       printf '%s' "$response" | python3 -c 'import json,sys; d=json.load(sys.stdin); sys.exit(0 if d.get("IsTor") is True else 1)' 2>/dev/null; then
      ok=1
      break
    fi
    sleep 5
  done
  ((ok == 1)) || fail 'Tor did not verify as a Tor exit within 90 seconds. Check relay reachability, clock and firewall.'
  info 'Tor is running and the Tor Project API confirms the connection is using Tor.'
}

curl_tor() {
  curl --fail --location --silent --show-error --connect-timeout 20 --max-time 300 --socks5-hostname 127.0.0.1:9050 "$@"
}
