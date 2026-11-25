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
  # MSR tools are optional CPU-tuning helpers, not Tor runtime dependencies.
  # Their absence must never block Tor bootstrap on a fresh/minimal host.
  command -v flock >/dev/null 2>&1 || missing+=(util-linux)
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

  # Debian's Tor unit is commonly Type=notify. A synchronous "systemctl
  # restart" waits for Tor's READY notification, which may be delayed while
  # Tor bootstraps (or never arrive on a restricted network). Queue the job
  # and independently probe the SOCKS listener so the installer remains
  # responsive and has its own bounded timeout.
  systemctl restart --no-block "$TOR_UNIT" || fail "Could not queue restart of $TOR_UNIT."

  local deadline=$((SECONDS + 180)) response
  while ((SECONDS < deadline)); do
    if response=$(curl --connect-timeout 3 --max-time 8 --silent --fail --socks5-hostname 127.0.0.1:9050 https://check.torproject.org/api/ip 2>/dev/null) &&
       printf '%s' "$response" | python3 -c 'import json,sys; d=json.load(sys.stdin); sys.exit(0 if d.get("IsTor") is True else 1)' 2>/dev/null; then
      info 'Tor is running and the Tor Project API confirms the connection is using Tor.'
      return 0
    fi
    sleep 5
  done

  printf '\n[MeowKit] Tor startup diagnostics for %s:\n' "$TOR_UNIT" >&2
  systemctl status "$TOR_UNIT" --no-pager --full >&2 || true
  journalctl -u "$TOR_UNIT" -n 40 --no-pager >&2 || true
  fail 'Tor did not become usable through SOCKS within 180 seconds. See the service diagnostics above; check outbound relay access, clock and firewall.'
}

curl_tor() {
  curl --fail --location --silent --show-error --connect-timeout 20 --max-time 300 --socks5-hostname 127.0.0.1:9050 "$@"
}
