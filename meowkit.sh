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
CPU_PERCENT=${CPU_PERCENT:-75}
RAM_PERCENT=${RAM_PERCENT:-75}
VM_CPU_REDUCTION_PERCENT=${VM_CPU_REDUCTION_PERCENT:-50}
SCHEDULE_ENABLED=${SCHEDULE_ENABLED:-1}
DAY_START=${DAY_START:-08:00}
DAY_END=${DAY_END:-16:00}
DAY_PERCENT=${DAY_PERCENT:-40}
TIMEZONE=${TIMEZONE:-Europe/Dublin}
VM_MODE=${VM_MODE:-auto}
THREADS_OVERRIDE=''
WORKER_NAME=${WORKER_NAME:-}
LOG_MODE=${LOG_MODE:-normal}

usage() {
  cat <<'TXT'
MeowKit 2.1
Usage: sudo ./meowkit.sh [--install|--repair|--status] [--threads N]
       [--worker-name NAME] [--log-mode normal|errors|none] [--ram-percent N] [--cpu-percent N]
       [--quiet|--verbose] [--vm-mode auto|shared|dedicated]

  --threads N             Use any integer from 1 to the available logical CPUs
  --worker-name NAME      Pool worker/rig identity (letters, digits, . _ -)
  --log-mode MODE         normal (journal), errors (stderr only), none (silent)
  --ram-percent N         Huge-page RAM budget, 1-100 (default 75)
  --cpu-percent N         Baseline CPU allocation, 1-100 (default 75)
  --vm-mode MODE          auto (adaptive), shared (50% baseline), dedicated
  --vm-reduction N        Reduce selected miner threads by N% while any Proxmox guest runs
  --day-percent N         Scheduled-window CPU allocation as % of baseline (1-100)
  --day-start HH:MM       Scheduled-window start (default 08:00)
  --day-end HH:MM         Scheduled-window end (default 16:00)
  --no-schedule           Disable time-based mining schedule
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
    --vm-reduction) shift; VM_CPU_REDUCTION_PERCENT=${1:?Missing VM reduction} ;;
    --day-percent) shift; DAY_PERCENT=${1:?Missing scheduled percentage} ;;
    --day-start) shift; DAY_START=${1:?Missing schedule start} ;;
    --day-end) shift; DAY_END=${1:?Missing schedule end} ;;
    --no-schedule) SCHEDULE_ENABLED=0 ;;
    --help|-h) usage; exit 0 ;;
    *) printf 'Unknown option: %s\n' "$1" >&2; usage; exit 2 ;;
  esac
  shift
done

[[ $EUID -eq 0 ]] || fail "Run as root: sudo $0"
[[ $VM_MODE == auto || $VM_MODE == shared || $VM_MODE == dedicated ]] || fail 'VM mode must be auto, shared or dedicated.'
[[ $LOG_MODE == normal || $LOG_MODE == errors || $LOG_MODE == none ]] || fail 'Log mode must be normal, errors or none.'
[[ -z $THREADS_OVERRIDE || $THREADS_OVERRIDE =~ ^[0-9]+$ ]] || fail '--threads must be a positive integer.'
[[ $RAM_PERCENT =~ ^[0-9]+$ ]] && ((RAM_PERCENT >= 1 && RAM_PERCENT <= 100)) || fail '--ram-percent must be 1-100.'
[[ $CPU_PERCENT =~ ^[0-9]+$ ]] && ((CPU_PERCENT >= 1 && CPU_PERCENT <= 100)) || fail '--cpu-percent must be 1-100.'
[[ $VM_CPU_REDUCTION_PERCENT =~ ^[0-9]+$ ]] && ((VM_CPU_REDUCTION_PERCENT >= 0 && VM_CPU_REDUCTION_PERCENT <= 90)) || fail '--vm-reduction must be 0-90.'
[[ $DAY_PERCENT =~ ^[0-9]+$ ]] && ((DAY_PERCENT >= 1 && DAY_PERCENT <= 100)) || fail '--day-percent must be 1-100.'

if [[ $ACTION == status ]]; then exec "$ROOT/commands/status.sh"; fi

show_menu() {
  clear 2>/dev/null || true
  cat <<'TXT'
╭────────────────────────────────────────────╮
│              MEOWKIT INSTALLER             │
│          MoneroOcean · XMRig · Tor         │
╰────────────────────────────────────────────╯

  [1] Recommended — 75% baseline CPU
  [2] Shared host — 50% baseline CPU
  [3] Maximum — 100% baseline CPU
  [4] Custom — enter your own CPU, RAM, schedule and VM settings
  [5] Repair installation
  [6] Uninstall MeowKit
  [7] Exit
TXT
  printf '\n  Log mode: 1) normal  2) errors only  3) none\n\n'
}

if [[ $ACTION == install && -t 0 && -z ${MEOWKIT_NONINTERACTIVE:-} ]]; then
  show_menu
  read -r -p '  Choose [1-7]: ' choice
  case "$choice" in
    1) CPU_PERCENT=75; CPU_PERCENT_EXPLICIT=1; VM_MODE=dedicated ;;
    2) CPU_PERCENT=50; CPU_PERCENT_EXPLICIT=1; VM_MODE=shared ;;
    3) CPU_PERCENT=100; CPU_PERCENT_EXPLICIT=1; VM_MODE=dedicated ;;
    4)
      read -r -p '  Baseline CPU allocation % [75] (1-100): ' CUSTOM_CPU
      CPU_PERCENT=${CUSTOM_CPU:-75}
      [[ $CPU_PERCENT =~ ^[0-9]+$ ]] && ((CPU_PERCENT>=1 && CPU_PERCENT<=100)) || fail 'CPU allocation must be 1-100%.'
      CPU_PERCENT_EXPLICIT=1; VM_MODE=dedicated
      read -r -p '  Huge-page RAM budget % [75] (1-100): ' CUSTOM_RAM
      RAM_PERCENT=${CUSTOM_RAM:-75}
      [[ $RAM_PERCENT =~ ^[0-9]+$ ]] && ((RAM_PERCENT>=1 && RAM_PERCENT<=100)) || fail 'Huge-page RAM budget must be 1-100%.'
      read -r -p '  CPU reduction while any Proxmox VM/container is running % [50] (0-90): ' CUSTOM_VM
      VM_CPU_REDUCTION_PERCENT=${CUSTOM_VM:-50}
      [[ $VM_CPU_REDUCTION_PERCENT =~ ^[0-9]+$ ]] && ((VM_CPU_REDUCTION_PERCENT>=0 && VM_CPU_REDUCTION_PERCENT<=90)) || fail 'VM reduction must be 0-90%.'
      read -r -p '  Enable time-based mining schedule? [Y/n]: ' CUSTOM_SCHEDULE
      case ${CUSTOM_SCHEDULE,,} in n|no) SCHEDULE_ENABLED=0 ;; *) SCHEDULE_ENABLED=1 ;; esac
      if (( SCHEDULE_ENABLED )); then
        read -r -p '  Reduced mining window start [08:00]: ' DAY_START
        DAY_START=${DAY_START:-08:00}
        read -r -p '  Reduced mining window end [16:00]: ' DAY_END
        DAY_END=${DAY_END:-16:00}
        read -r -p '  CPU allocation during window (% of baseline) [40]: ' DAY_PERCENT
        DAY_PERCENT=${DAY_PERCENT:-40}
        [[ $DAY_PERCENT =~ ^[0-9]+$ ]] && ((DAY_PERCENT>=1 && DAY_PERCENT<=100)) || fail 'Scheduled CPU allocation must be 1-100%.'
        for t in "$DAY_START" "$DAY_END"; do [[ $t =~ ^([01][0-9]|2[0-3]):[0-5][0-9]$ ]] || fail "Invalid schedule time: $t"; done
        [[ $DAY_START != "$DAY_END" ]] || fail 'Schedule start and end must differ.'
      fi
      ;;
    5) ACTION=repair ;;
    6) read -r -p '  Remove MeowKit? [y/N]: ' confirm; [[ ${confirm,,} == y ]] || exit 0; "$ROOT/commands/uninstall.sh"; exit $? ;;
    7) exit 0 ;;
    *) fail 'Invalid menu selection.' ;;
  esac
  if [[ $ACTION == install ]]; then
    saved_worker=''
    [[ -r /etc/meowkit/worker-name ]] && IFS= read -r saved_worker < /etc/meowkit/worker-name || true
    suggested_name=${WORKER_NAME:-${saved_worker:-$(hostname -s 2>/dev/null || echo meow-worker)}}
    read -r -p "  Worker name [${suggested_name}]: " WORKER_NAME
    WORKER_NAME=${WORKER_NAME:-$suggested_name}
    printf '\nLogging: 1) normal  2) errors only  3) none\n'
    read -r -p '  Choose [1]: ' log_choice
    case ${log_choice:-1} in
      1) LOG_MODE=normal ;;
      2) LOG_MODE=errors ;;
      3) LOG_MODE=none ;;
      *) warn 'Invalid choice; using normal logs.'; LOG_MODE=normal ;;
    esac
  fi
fi

if [[ $ACTION == repair ]]; then
  REPAIR=1
  if [[ -r /etc/meowkit/worker-name ]]; then WORKER_NAME=$(</etc/meowkit/worker-name); fi
  if [[ -r /etc/meowkit/resource-profile.conf ]]; then
    # Root-owned MeowKit profile; preserve baseline and schedule on repair.
    source /etc/meowkit/resource-profile.conf
    CPU_PERCENT_EXPLICIT=1
    CPU_PERCENT=${CPU_PERCENT:-75}
    RAM_PERCENT=${RAM_PERCENT:-75}
    VM_CPU_REDUCTION_PERCENT=${VM_CPU_REDUCTION_PERCENT:-50}
    THREADS_OVERRIDE=${BASE_THREADS:-}
  fi
  if [[ -r /etc/meowkit/settings.conf ]]; then source /etc/meowkit/settings.conf; fi
  info 'Repair mode: preserving worker identity, baseline CPU, RAM budget, VM policy and schedule.'
fi

run_install
