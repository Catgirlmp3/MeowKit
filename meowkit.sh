#!/usr/bin/env bash
set -uo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
source "$ROOT/lib/common.sh"
source "$ROOT/lib/tor.sh"
source "$ROOT/lib/system.sh"
source "$ROOT/lib/miner.sh"

MODE=quiet
ACTION=install
REPAIR=0
RAM_PERCENT=${RAM_PERCENT:-75}
VM_MODE=${VM_MODE:-auto}
THREADS_OVERRIDE=''
WORKER_NAME=${WORKER_NAME:-}
LOG_MODE=${LOG_MODE:-normal}

usage() {
  cat <<'TXT'
MeowKit 2.1
Usage: sudo ./meowkit.sh [--install|--repair|--status] [--threads N]
       [--worker-name NAME] [--log-mode normal|errors|none] [--ram-percent N]
       [--quiet|--verbose] [--vm-mode auto|shared|dedicated]

  --threads N             Use any integer from 1 to the available logical CPUs
  --worker-name NAME      Pool worker/rig identity (letters, digits, . _ -)
  --log-mode MODE         normal (journal), errors (stderr only), none (silent)
  --ram-percent N         Huge-page budget cap, 10-90 (default 75)
  --vm-mode MODE          auto, shared or dedicated
  --repair                Repair managed components
  --status                Show current status
  --help                  Show this help
TXT
}
while (($#)); do
  case "$1" in
    --quiet) MODE=quiet ;;
    --verbose) MODE=verbose ;;
    --status) ACTION=status ;;
    --install) ACTION=install ;;
    --repair) ACTION=repair ;;
    --cpu-percent) shift; CPU_PERCENT=${1:?Missing percentage}; CPU_PERCENT_EXPLICIT=1 ;;
    --vm-mode) shift; VM_MODE=${1:?Missing VM mode} ;;
    --threads) shift; THREADS_OVERRIDE=${1:?Missing thread count} ;;
    --worker-name) shift; WORKER_NAME=${1:?Missing worker name} ;;
    --log-mode) shift; LOG_MODE=${1:?Missing log mode} ;;
    --ram-percent) shift; RAM_PERCENT=${1:?Missing RAM percentage} ;;
    --help|-h) usage; exit 0 ;;
    *) printf 'Unknown option: %s\n' "$1" >&2; usage; exit 2 ;;
  esac
  shift
done

[[ $EUID -eq 0 ]] || fail "Run as root: sudo $0"
[[ $VM_MODE == auto || $VM_MODE == shared || $VM_MODE == dedicated ]] || fail 'VM mode must be auto, shared or dedicated.'
[[ $LOG_MODE == normal || $LOG_MODE == errors || $LOG_MODE == none ]] || fail 'Log mode must be normal, errors or none.'
[[ -z $THREADS_OVERRIDE || $THREADS_OVERRIDE =~ ^[0-9]+$ ]] || fail '--threads must be a positive integer.'
[[ $RAM_PERCENT =~ ^[0-9]+$ ]] && ((RAM_PERCENT >= 10 && RAM_PERCENT <= 90)) || fail '--ram-percent must be 10-90.'

if [[ $ACTION == status ]]; then exec "$ROOT/commands/status.sh"; fi

if [[ $ACTION == install && -t 0 && -z ${MEOWKIT_NONINTERACTIVE:-} ]]; then
  printf '\n╭────────────── MEOWKIT ──────────────╮\n│ Modular XMRig / MoneroOcean setup  │\n╰────────────────────────────────────╯\n'
  read -r -p 'Worker name [hostname]: ' WORKER_NAME
  WORKER_NAME=${WORKER_NAME:-$(hostname -s 2>/dev/null || echo meow-worker)}
  read -r -p "Threads [30% of $(nproc)]: " THREADS_OVERRIDE
  read -r -p 'Huge-page RAM budget [75%]: ' RAM_PERCENT
  RAM_PERCENT=${RAM_PERCENT:-75}
  printf '\nLogging: 1) normal  2) errors only  3) none\n'
  read -r -p 'Choose [1]: ' log_choice
  case ${log_choice:-1} in 1) LOG_MODE=normal ;; 2) LOG_MODE=errors ;; 3) LOG_MODE=none ;; *) warn 'Invalid choice; using normal logs.'; LOG_MODE=normal ;; esac
  printf 'Press Ctrl+C at any time to cancel.\n\n'
fi

if [[ $ACTION == repair ]]; then
  REPAIR=1
  if [[ -z $THREADS_OVERRIDE && -f /etc/meowkit/worker-name ]]; then WORKER_NAME=$(</etc/meowkit/worker-name); fi
  if [[ -z $THREADS_OVERRIDE && -f /etc/meowkit/hugepages.conf ]]; then source /etc/meowkit/hugepages.conf; fi
  if [[ -z $THREADS_OVERRIDE ]]; then
    THREADS_OVERRIDE=$(systemctl show meowkit.service -p ExecStart --value 2>/dev/null | sed -n 's/.*--threads=\([0-9][0-9]*\).*/\1/p' || true)
  fi
  info 'Repair mode: preserving saved worker identity and existing settings where available.'
fi
run_install
