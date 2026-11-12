#!/usr/bin/env bash
MEOWKIT_VERSION='2.1.0'
MEOWKIT_DIR='/etc/meowkit'
MEOWKIT_BIN='/usr/local/bin/meowkit-xmrig'
MEOWKIT_SERVICE='/etc/systemd/system/meowkit.service'
WORKDIR=''
CURRENT_STEP='startup'
MODE=${MODE:-quiet}
CPU_PERCENT=${CPU_PERCENT:-30}
CPU_PERCENT_EXPLICIT=${CPU_PERCENT_EXPLICIT:-0}
LOG_MODE=${LOG_MODE:-normal}

log() { [[ ${MODE:-quiet} == verbose ]] && printf '[MeowKit] %s\n' "$*"; return 0; }
info() { printf '[+] %s\n' "$*"; }
warn() { printf '[!] %s\n' "$*" >&2; }
cleanup_temp() {
  if [[ -n ${WORKDIR:-} && -d ${WORKDIR:-} ]]; then rm -rf -- "$WORKDIR" || true; fi
}
on_interrupt() {
  printf '\n[!] Interrupted by Ctrl+C. Cleaning temporary files; managed services/configuration were not rolled back.\n' >&2
  cleanup_temp
  exit 130
}
trap on_interrupt INT TERM
on_exit() { local rc=$?; cleanup_temp; ((rc == 0)) || log "Exited with status $rc"; return 0; }
trap on_exit EXIT

fail() {
  local message=$*
  printf '\n[!] MEOWKIT ERROR\nStep: %s\nProblem: %s\n' "$CURRENT_STEP" "$message" >&2
  printf 'No unsafe fallback was attempted. Correct the issue and rerun; existing managed files were left in place where possible.\n' >&2
  cleanup_temp
  exit 1
}
require_cmd() { command -v "$1" >/dev/null 2>&1 || fail "Required command is missing: $1"; }
begin_step() { CURRENT_STEP=$1; log "$1"; }
make_workdir() { WORKDIR=$(mktemp -d /tmp/meowkit.XXXXXX) || fail 'Could not create temporary working directory.'; chmod 700 "$WORKDIR" || fail 'Could not secure temporary working directory.'; }
