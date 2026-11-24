#!/usr/bin/env bash
set -u
log(){ printf '[MeowKit MSR] %s\n' "$*"; }
# Load the module with writes enabled. If it is already loaded, a modprobe
# options file alone cannot change its live parameter: update sysfs as well.
if [[ ! -d /sys/module/msr ]]; then
  if command -v modprobe >/dev/null 2>&1; then
    modprobe msr allow_writes=on 2>/dev/null || modprobe msr 2>/dev/null || {
      log "Kernel/hypervisor refused to load msr; continue without MSR tuning."
      exit 0
    }
  else
    log "modprobe unavailable; cannot load msr."
    exit 0
  fi
fi
P=/sys/module/msr/parameters/allow_writes
if [[ -e $P ]]; then
  if [[ -w $P ]]; then printf 'on\n' > "$P" 2>/dev/null || true; fi
  value=$(cat "$P" 2>/dev/null || echo unknown)
  case "$value" in on|1|Y|y) log "msr.allow_writes=$value enabled.";;
    *) log "msr module loaded but allow_writes reports '$value'; kernel may restrict writes.";;
  esac
else
  log "Kernel does not expose msr.allow_writes; no generic write fallback attempted."
fi
if command -v rdmsr >/dev/null 2>&1 && rdmsr -p 0 0x10 >/dev/null 2>&1; then
  log "Read-only MSR probe passed on CPU 0."
else
  log "MSR read probe failed; check /dev/cpu/*/msr, kernel lockdown/Secure Boot and hypervisor passthrough."
fi
# Do not issue generic WRMSR writes here: XMRig applies CPU-specific RandomX
# presets and can restore the prior values when it exits.
exit 0
