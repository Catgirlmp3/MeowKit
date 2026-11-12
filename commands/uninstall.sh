#!/usr/bin/env bash
set -uo pipefail
[[ $EUID -eq 0 ]] || { echo 'Run as root.' >&2; exit 1; }
failed=0
run() {
  local label=$1; shift
  if "$@"; then printf '[+] %s\n' "$label"; else printf '[!] %s failed; continuing.\n' "$label" >&2; failed=1; fi
}
run 'Stop and disable MeowKit service' systemctl disable --now meowkit.service
run 'Remove MeowKit service and executable' rm -f /etc/systemd/system/meowkit.service /usr/local/bin/meowkit-xmrig
run 'Remove MeowKit helper scripts' rm -f /usr/local/sbin/meowkit-tor-check /usr/local/sbin/meowkit-hugepages
run 'Remove MeowKit MSR configuration' rm -f /etc/modules-load.d/meowkit-msr.conf /etc/modprobe.d/meowkit-msr.conf

# Remove only the known legacy quiet override, and only if its contents match
# the exact two-line override. Never delete a user's entire drop-in directory.
quiet=/etc/systemd/system/meowkit.service.d/quiet.conf
if [[ -f $quiet ]] && grep -qxF '[Service]' "$quiet" &&
   grep -qxF 'StandardOutput=null' "$quiet" &&
   grep -qxF 'StandardError=null' "$quiet" &&
   [[ $(wc -l < "$quiet") -eq 3 ]]; then
  run 'Remove legacy MeowKit quiet override' rm -f "$quiet"
fi
if [[ -d /etc/systemd/system/meowkit.service.d ]]; then
  rmdir /etc/systemd/system/meowkit.service.d 2>/dev/null || true
fi

# Remove MeowKit's application directory only if it is a real directory.
if [[ -d /etc/meowkit ]]; then run 'Remove MeowKit application settings' rm -rf -- /etc/meowkit
elif [[ -e /etc/meowkit ]]; then echo '[!] /etc/meowkit is not a directory; left untouched.' >&2; failed=1
fi

# Remove only MeowKit's exact Tor marker/directive pair. Keep all other Tor
# directives and user-created systemd overrides intact.
if [[ -f /etc/tor/torrc ]]; then
  tmp=$(mktemp /etc/tor/torrc.meowkit.XXXXXX) || { echo '[!] Could not create torrc temporary file; left unchanged.' >&2; failed=1; tmp=''; }
  if [[ -n $tmp ]]; then
    if awk '
      $0 == "# MeowKit managed SOCKS5 listener" {
        if (getline nextline > 0) {
          if (nextline == "SocksPort 127.0.0.1:9050") next
          print
          print nextline
          next
        }
      }
      { print }
    ' /etc/tor/torrc > "$tmp" &&
       chmod --reference=/etc/tor/torrc "$tmp" &&
       chown --reference=/etc/tor/torrc "$tmp" &&
       cat "$tmp" > /etc/tor/torrc; then
      echo '[+] Removed MeowKit Tor listener directive.'
    else
      echo '[!] Could not safely rewrite torrc; original content may need manual review.' >&2
      failed=1
    fi
    rm -f "$tmp"
  fi
fi
run 'Reload systemd' systemctl daemon-reload
if ((failed)); then
  echo 'Uninstall completed with warnings. Tor packages, unrelated services, and user-owned overrides were retained.' >&2
  exit 1
fi
echo 'MeowKit removed. Tor itself and unrelated system configuration were retained.'
