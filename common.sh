#!/usr/bin/env bash
MEOWKIT_VERSION='2.0.0'
MEOWKIT_DIR='/etc/meowkit'
MEOWKIT_BIN='/usr/local/bin/meowkit-xmrig'
MEOWKIT_SERVICE='/etc/systemd/system/meowkit.service'
WORKDIR=''
CURRENT_STEP='startup'
MODE=${MODE:-quiet}
CPU_PERCENT=${CPU_PERCENT:-75}

log() { [[ ${MODE:-quiet} == verbose ]] && printf '[MeowKit] %s\n' "$*"; return 0; }
info() { printf '[+] %s\n' "$*"; }
fail() { printf '\n[!] MEOWKIT ERROR\nStep: %s\nProblem: %s\n' "$CURRENT_STEP" "$*" >&2; printf 'Suggested checks: verify network access, available disk space and systemd status.\n' >&2; cleanup_temp; if [[ -t 1 ]]; then sleep 15; clear 2>/dev/null || printf '\033[2J\033[H'; fi; exit 1; }
cleanup_temp() { [[ -n ${WORKDIR:-} && -d ${WORKDIR:-} ]] && rm -rf -- "$WORKDIR"; }
handle_unexpected_error() {
  local rc=$1 line=$2 command=$3
  printf '\n[!] MEOWKIT ERROR\nStep: %s\nProblem: command failed (exit %s) near line %s.\nCommand: %s\n' \
    "$CURRENT_STEP" "$rc" "$line" "$command" >&2
  printf 'Suggested fix: rerun with --verbose and check the named component/configuration.\n' >&2
  cleanup_temp
  if [[ -t 1 ]]; then sleep 15; clear 2>/dev/null || printf '\033[2J\033[H'; fi
  exit "$rc"
}
on_exit() { local rc=$?; cleanup_temp; if ((rc != 0)); then log "Installer exited with status $rc"; fi; }
trap 'handle_unexpected_error "$?" "$LINENO" "$BASH_COMMAND"' ERR
trap on_exit EXIT

require_cmd() { command -v "$1" >/dev/null 2>&1 || fail "Required command is missing: $1"; }

begin_step() { CURRENT_STEP=$1; log "$1"; }

make_workdir() { WORKDIR=$(mktemp -d /tmp/meowkit.XXXXXX) || fail 'Could not create temporary working directory.'; chmod 700 "$WORKDIR"; }
