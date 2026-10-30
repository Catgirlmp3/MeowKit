#!/usr/bin/env bash
set -Eeuo pipefail
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
source "$ROOT/lib/common.sh"
source "$ROOT/lib/tor.sh"
source "$ROOT/lib/system.sh"
source "$ROOT/lib/miner.sh"

MODE=quiet
ACTION=install

usage() {
  cat <<'TXT'
MeowKit
Usage: sudo ./meowkit.sh [--quiet|--verbose] [--status|--install]

  --quiet     Minimal installer output (default)
  --verbose   Show detailed progress
  --status    Show service and Tor status; does not display logs
  --install   Run the installer
  --help      Show this help
TXT
}

while (($#)); do
  case "$1" in
    --quiet) MODE=quiet ;;
    --verbose) MODE=verbose ;;
    --status) ACTION=status ;;
    --install) ACTION=install ;;
    --help|-h) usage; exit 0 ;;
    *) printf 'Unknown option: %s\n' "$1"; usage; exit 2 ;;
  esac
  shift
done

if [[ $EUID -ne 0 ]]; then
  printf 'Please run MeowKit as root: sudo %s\n' "$0" >&2
  exit 1
fi

if [[ $ACTION == status ]]; then
  printf 'MeowKit service: '
  if systemctl is-active --quiet meowkit.service; then printf 'active\n'; else printf 'inactive\n'; fi
  printf 'Enabled at boot: '
  if systemctl is-enabled --quiet meowkit.service 2>/dev/null; then printf 'yes\n'; else printf 'no\n'; fi
  printf 'Tor: '
  if systemctl is-active --quiet tor.service; then printf 'active\n'; else printf 'not active\n'; fi
  printf 'SOCKS5: '
  if curl --connect-timeout 8 --max-time 15 --silent --fail --socks5-hostname 127.0.0.1:9050 https://check.torproject.org/api/ip >/dev/null 2>&1; then printf 'reachable through Tor\n'; else printf 'unavailable\n'; fi
  exit 0
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
      Recheck Tor, configuration and service

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
    2) read -r -p '  CPU allocation percentage [75]: ' CUSTOM_CPU; CUSTOM_CPU=${CUSTOM_CPU:-75}; [[ $CUSTOM_CPU =~ ^[0-9]+$ ]] && ((CUSTOM_CPU>=10 && CUSTOM_CPU<=90)) || fail 'Custom CPU percentage must be 10–90.'; CPU_PERCENT=$CUSTOM_CPU ;;
    3) ;;
    4) read -r -p '  Remove MeowKit? [y/N]: ' confirm; [[ ${confirm,,} == y ]] || exit 0; "$ROOT/commands/uninstall.sh"; exit $? ;;
    5) exit 0 ;;
    *) fail 'Invalid menu selection.' ;;
  esac
  read -r -p '  Output mode [Q/V]: ' selected_mode
  [[ ${selected_mode,,} == v ]] && MODE=verbose
fi

run_install

if [[ -t 1 ]]; then
  printf '\nMeowKit installation completed. Press Enter to clear the terminal.'
  read -r _ || true
  clear 2>/dev/null || printf '\033[2J\033[H'
fi
