#!/usr/bin/env bash
set -Eeuo pipefail

CPU_PERCENT_EXPLICIT=0
[[ ${CPU_PERCENT+x} ]] && CPU_PERCENT_EXPLICIT=1
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

usage() {
  cat <<'TXT'
MeowKit
Usage: sudo ./meowkit.sh [--quiet|--verbose] [--status|--install|--repair]
                         [--cpu-percent 50|75|100] [--vm-mode auto|shared|dedicated]
                         [--threads N] [--ram-percent N]

  --cpu-percent 50|75|100  Allocate 50%, 75%, or all available CPUs
  --vm-mode auto            Use 50% when running Proxmox guests are detected; otherwise 75%
  --vm-mode shared          Use 50% when another VM/workload shares this host
  --vm-mode dedicated       Use the selected CPU percentage (75% by default)
  --threads N               Set an explicit thread count (minimum 50% of available CPUs)
  --ram-percent N           Huge-page budget percentage (10-90; default 75)
  --quiet                   Minimal installer output
  --verbose                 Detailed progress
  --status                  Show service and Tor status (does not change the system)
  --install                 Run installer
  --repair                  Repair managed components
  --help                    Show this help
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
    --ram-percent) shift; RAM_PERCENT=${1:?Missing RAM percentage} ;;
    --help|-h) usage; exit 0 ;;
    *) printf 'Unknown option: %s\n' "$1" >&2; usage; exit 2 ;;
  esac
  shift
done

if [[ $EUID -ne 0 ]]; then printf 'Please run MeowKit as root: sudo %s\n' "$0" >&2; exit 1; fi
[[ $VM_MODE == auto || $VM_MODE == shared || $VM_MODE == dedicated ]] || fail 'VM mode must be auto, shared, or dedicated.'
if [[ -n $THREADS_OVERRIDE ]]; then [[ $THREADS_OVERRIDE =~ ^[0-9]+$ ]] || fail '--threads must be a positive integer.'; fi

# Status is informational: an inactive service is a reported state, not an installer error.
if [[ $ACTION == status ]]; then
  if "$ROOT/commands/status.sh"; then exit 0; else status_rc=$?; exit "$status_rc"; fi
fi

show_menu() {
  clear 2>/dev/null || true
  cat <<'TXT'
╭────────────────────────────────────────────╮
│              MEOWKIT INSTALLER             │
│          MoneroOcean · XMRig · Tor         │
╰────────────────────────────────────────────╯

  [1] Recommended — 75% CPU allocation
  [2] Shared VM — 50% CPU allocation
  [3] Maximum — 100% CPU allocation (all available CPUs)
  [4] Custom — choose 50%, 75% or 100%, plus RAM budget
  [5] Repair installation
  [6] Uninstall MeowKit
  [7] Exit
TXT
  printf '\n  Output mode: [Q] Quiet  [V] Verbose\n\n'
}

if [[ $ACTION == install && -t 0 && $MODE == quiet ]]; then
  show_menu
  read -r -p '  Choose [1-7]: ' choice
  case "$choice" in
    1) CPU_PERCENT=75; CPU_PERCENT_EXPLICIT=1; VM_MODE=dedicated ;;
    2) CPU_PERCENT=50; CPU_PERCENT_EXPLICIT=1; VM_MODE=shared ;;
    3) CPU_PERCENT=100; CPU_PERCENT_EXPLICIT=1; VM_MODE=dedicated ;;
    4)
      read -r -p '  CPU allocation [50/75/100, default 75]: ' CUSTOM_CPU
      CUSTOM_CPU=${CUSTOM_CPU:-75}
      [[ $CUSTOM_CPU == 50 || $CUSTOM_CPU == 75 || $CUSTOM_CPU == 100 ]] || fail 'Choose 50, 75 or 100.'
      read -r -p '  Huge-page RAM budget percentage [75]: ' CUSTOM_RAM
      CUSTOM_RAM=${CUSTOM_RAM:-75}
      [[ $CUSTOM_RAM =~ ^[0-9]+$ ]] && ((CUSTOM_RAM>=10 && CUSTOM_RAM<=90)) || fail 'RAM percentage must be 10–90.'
      CPU_PERCENT=$CUSTOM_CPU; CPU_PERCENT_EXPLICIT=1; VM_MODE=dedicated; RAM_PERCENT=$CUSTOM_RAM
      ;;
    5) ACTION=repair ;;
    6)
      read -r -p '  Remove MeowKit? [y/N]: ' confirm
      if [[ ${confirm,,} == y ]]; then
        if "$ROOT/commands/uninstall.sh"; then exit 0; else uninstall_rc=$?; exit "$uninstall_rc"; fi
      else
        exit 0
      fi
      ;;
    7) exit 0 ;;
    *) fail 'Invalid menu selection.' ;;
  esac
  read -r -p '  Output mode [Q/V]: ' selected_mode
  if [[ ${selected_mode,,} == v ]]; then MODE=verbose; fi
fi

if [[ $ACTION == repair ]]; then
  REPAIR=1
  if ((CPU_PERCENT_EXPLICIT == 0)) && [[ -f /etc/meowkit/config.json ]]; then
    saved_threads=$(systemctl show meowkit.service -p ExecStart --value 2>/dev/null | sed -n 's/.*--threads=\([0-9][0-9]*\).*/\1/p' || true)
    if [[ $saved_threads =~ ^[0-9]+$ ]]; then THREADS_OVERRIDE=$saved_threads; fi
  fi
  if [[ -r /etc/meowkit/hugepages.conf ]]; then source /etc/meowkit/hugepages.conf; fi
  info 'Repair mode: checking components and preserving worker identity.'
fi
run_install

if [[ -t 1 ]]; then
  printf '\nMeowKit operation completed. Press Enter to clear the terminal.'
  read -r _ || true
  clear 2>/dev/null || printf '\033[2J\033[H'
fi
