#!/usr/bin/env bash
set -Eeuo pipefail

# Preserve whether CPU_PERCENT was supplied by the caller before common.sh
# applies its default. Proxmox tuning must never override an explicit choice.
CPU_PERCENT_EXPLICIT=0
[[ ${CPU_PERCENT+x} ]] && CPU_PERCENT_EXPLICIT=1

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
source "$ROOT/lib/common.sh"
source "$ROOT/lib/tor.sh"
source "$ROOT/lib/system.sh"
source "$ROOT/lib/miner.sh"

MODE=quiet
ACTION=install
RAM_PERCENT=${RAM_PERCENT:-75}

usage() {
  cat <<'TXT'
MeowKit
Usage: sudo ./meowkit.sh [--quiet|--verbose] [--status|--install|--repair]

  --quiet     Minimal installer output (default)
  --verbose   Show detailed progress
  --status    Show service and Tor status; does not display logs
  --install   Run the installer
  --repair    Reconcile installed files and restart the service
  --help      Show this help
TXT
}

while (($#)); do
  case "$1" in
    --quiet) MODE=quiet ;;
    --verbose) MODE=verbose ;;
    --status) ACTION=status ;;
    --install) ACTION=install ;;
    --repair) ACTION=repair ;;
    --help|-h) usage; exit 0 ;;
    *) printf 'Unknown option: %s\n' "$1" >&2; usage; exit 2 ;;
  esac
  shift
done

if [[ $EUID -ne 0 ]]; then
  printf 'Please run MeowKit as root: sudo %s\n' "$0" >&2
  exit 1
fi

if [[ $ACTION == status ]]; then
  "$ROOT/commands/status.sh"
  exit $?
fi

show_menu() {
  clear 2>/dev/null || true
  cat <<'TXT'
╭────────────────────────────────────────────╮
│              MEOWKIT INSTALLER             │
│          MoneroOcean · XMRig · Tor         │
╰────────────────────────────────────────────╯

  [1] Recommended installation
      Automatic hardware detection and tuning

  [2] Custom installation
      Choose resource limits and optimisations

  [3] Repair installation
      Reconcile configuration and restart the service

  [4] Uninstall MeowKit
      Remove MeowKit components

  [5] Exit
TXT
  printf '\n  Output mode: [Q] Quiet  [V] Verbose\n\n'
}

if [[ -t 0 && $MODE == quiet ]]; then
  show_menu
  read -r -p '  Choose [1-5]: ' choice
  case "$choice" in
    1) ;;
    2)
      read -r -p '  CPU allocation percentage [75]: ' CUSTOM_CPU; CUSTOM_CPU=${CUSTOM_CPU:-75}
      [[ $CUSTOM_CPU =~ ^[0-9]+$ ]] && ((CUSTOM_CPU>=10 && CUSTOM_CPU<=90)) || fail 'Custom CPU percentage must be 10–90.'
      read -r -p '  Huge-page RAM budget percentage [75]: ' CUSTOM_RAM; CUSTOM_RAM=${CUSTOM_RAM:-75}
      [[ $CUSTOM_RAM =~ ^[0-9]+$ ]] && ((CUSTOM_RAM>=10 && CUSTOM_RAM<=90)) || fail 'RAM percentage must be 10–90.'
      CPU_PERCENT=$CUSTOM_CPU; CPU_PERCENT_EXPLICIT=1; RAM_PERCENT=$CUSTOM_RAM
      ;;
    3) ACTION=repair ;;
    4) read -r -p '  Remove MeowKit? [y/N]: ' confirm; [[ ${confirm,,} == y ]] || exit 0; "$ROOT/commands/uninstall.sh"; exit $? ;;
    5) exit 0 ;;
    *) fail 'Invalid menu selection.' ;;
  esac
  read -r -p '  Output mode [Q/V]: ' selected_mode
  [[ ${selected_mode,,} == v ]] && MODE=verbose
fi

if [[ $ACTION == repair ]]; then
  info 'Repair mode: existing worker identity is preserved; managed configuration and service will be reconciled.'
fi
run_install

if [[ -t 1 ]]; then
  printf '\nMeowKit installation completed. Press Enter to clear the terminal.'
  read -r _ || true
  clear 2>/dev/null || printf '\033[2J\033[H'
fi
