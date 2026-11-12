#!/usr/bin/env bash
bootstrap_tor() {
  begin_step 'Tor bootstrap'
  export DEBIAN_FRONTEND=noninteractive

  # Check Debian package state rather than only looking for the executable.
  # A stray tor binary is not proof that the package's systemd units are installed.
  local packages=(tor curl python3 tar gzip ca-certificates)
  local missing=() package status
  for package in "${packages[@]}"; do
    status=$(dpkg-query -W -f='${db:Status-Status}' "$package" 2>/dev/null || true)
    [[ $status == installed ]] || missing+=("$package")
  done

  if (("${#missing[@]}" > 0)); then
    info "Installing missing packages: ${missing[*]}"
    apt-get update -qq || fail 'Package index update failed while installing Tor prerequisites.'
    apt-get install -y "${missing[@]}" || fail 'Could not install Tor and its required packages.'
  fi

  command -v tor >/dev/null 2>&1 || fail 'The Tor package is installed but the tor executable is missing.'
  install -d -m 755 /etc/tor
  local torrc=/etc/tor/torrc
  [[ -f $torrc ]] || touch "$torrc"
  local backup="$torrc.meowkit-backup.$(date +%Y%m%d%H%M%S)"
  cp -a "$torrc" "$backup" || fail 'Could not back up the existing Tor configuration.'
  if ! grep -Eq '^[[:space:]]*SocksPort[[:space:]]+127\.0\.0\.1:9050([[:space:]]|$)' "$torrc"; then
    printf '\n# MeowKit managed SOCKS5 listener\nSocksPort 127.0.0.1:9050\n' >> "$torrc"
  fi
  if ! tor --verify-config -f "$torrc" >/dev/null 2>&1; then
    cp -a "$backup" "$torrc" || printf 'Warning: Tor configuration rollback failed; backup: %s\n' "$backup" >&2
    fail 'Tor configuration validation failed. Previous configuration restored where possible.'
  fi

  # Refresh systemd's view after package installation, then select Debian's
  # per-instance unit where available (the process runs in tor@default).
  systemctl daemon-reload || fail 'systemd could not reload unit files after Tor installation.'
  if systemctl cat tor@default.service >/dev/null 2>&1; then
    TOR_UNIT=tor@default.service
  elif systemctl cat tor.service >/dev/null 2>&1; then
    TOR_UNIT=tor.service
  else
    fail 'The Tor package is installed, but neither tor@default.service nor tor.service is available.'
  fi

  systemctl enable "$TOR_UNIT" >/dev/null 2>&1 || fail "Could not enable $TOR_UNIT at boot."
  # Do not wait for systemd's Type=notify job to finish: some environments
  # keep the unit in 'activating' even after the SOCKS listener is usable.
  systemctl restart --no-block "$TOR_UNIT" || info "Could not queue restart for $TOR_UNIT; checking its existing listener."

  local ok=0 response
  for _ in {1..18}; do
    if response=$(curl --connect-timeout 5 --max-time 12 --silent --fail --socks5-hostname 127.0.0.1:9050 https://check.torproject.org/api/ip 2>/dev/null) &&
       printf '%s' "$response" | python3 -c 'import json,sys; d=json.load(sys.stdin); sys.exit(0 if d.get("IsTor") is True else 1)' 2>/dev/null; then
      ok=1
      break
    fi
    sleep 5
  done

  if ((ok == 1)); then
    info "Tor SOCKS5 connection verified through $TOR_UNIT."
  else
    info "Tor is installed and enabled, but its SOCKS5 connection is not ready yet. MeowKit will retry through the proxy; no direct-connection fallback is used."
  fi
}

curl_tor() {
  curl --fail --location --silent --show-error --connect-timeout 20 --max-time 300 --socks5-hostname 127.0.0.1:9050 "$@"
}
