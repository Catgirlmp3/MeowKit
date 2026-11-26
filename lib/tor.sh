#!/usr/bin/env bash
bootstrap_tor() {
  begin_step 'Tor bootstrap'
  export DEBIAN_FRONTEND=noninteractive

  # Install Tor first, before refreshing package indexes or installing the
  # other tools. This allows a valid cached Debian package index to bootstrap
  # Tor even when an unrelated APT source (for example, an unsubscribed
  # Proxmox enterprise repository) rejects apt-get update.
  local status package
  status=$(dpkg-query -W -f='${db:Status-Status}' tor 2>/dev/null || true)
  if [[ $status != installed ]]; then
    info 'Installing Tor first from the currently available APT package indexes.'
    if ! apt-get install -y tor; then
      info 'Tor was not installable from the cached indexes; refreshing APT indexes and retrying.'
      apt-get update || info 'APT index refresh reported errors; retrying with the indexes that were downloaded.'
      apt-get install -y tor || fail 'Could not install Tor. Check the Debian repository configuration and package-index errors above.'
    fi
  fi

  # Install the remaining runtime/download tools only after Tor is present.
  # Prefer cached indexes; refresh and retry only if the package install needs it.
  local packages=(curl python3 tar gzip ca-certificates git build-essential cmake libuv1-dev libhwloc-dev)
  local missing=()
  for package in "${packages[@]}"; do
    status=$(dpkg-query -W -f='${db:Status-Status}' "$package" 2>/dev/null || true)
    [[ $status == installed ]] || missing+=("$package")
  done

  if (("${#missing[@]}" > 0)); then
    info "Installing remaining prerequisites: ${missing[*]}"
    if ! apt-get install -y "${missing[@]}"; then
      info 'Prerequisite installation failed with the cached indexes; refreshing APT indexes and retrying.'
      apt-get update || info 'APT index refresh reported errors; retrying with the indexes that were downloaded.'
      apt-get install -y "${missing[@]}" || fail 'Could not install the remaining MeowKit prerequisites. Check the APT errors above.'
    fi
  fi

  require_cmd tor
  require_cmd curl
  require_cmd python3

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

  # Do not block installation waiting for a Tor circuit. XMRig source is
  # fetched directly from GitHub; the service performs a strict Tor identity
  # check immediately before the miner can start.
  info "Tor is enabled through $TOR_UNIT. Circuit readiness will be verified at miner startup; installation will not wait for Tor."

}

curl_tor() {
  curl --fail --location --silent --show-error --connect-timeout 20 --max-time 300 --socks5-hostname 127.0.0.1:9050 "$@"
}
