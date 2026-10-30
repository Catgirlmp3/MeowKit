# MeowKit 2.0.4

A modular Debian/Ubuntu/Proxmox installer for XMRig + MoneroOcean using a local Tor SOCKS5 proxy.

## Install

Run as root:

```bash
sudo ./meowkit.sh
```

Quiet output is the default. Use `--verbose` for progress details and `--status` to inspect service state without displaying logs. Error screens remain visible for about 15 seconds before the terminal is cleared.

## Network behaviour

- Tor SOCKS5 listener: `127.0.0.1:9050`
- MoneroOcean pool: `gulf.moneroocean.stream:10001`
- XMRig is configured to use the SOCKS5 proxy.
- GitHub release metadata and XMRig download are fetched through Tor.
- Initial APT installation of Tor is the bootstrap exception because Tor must be installed before it can provide a proxy. Once Tor is running, MeowKit's own remote downloads use Tor.
- There is no direct-connection fallback for XMRig or GitHub downloads.

## Service

The miner service is enabled automatically at installation and starts at boot. It restarts after an unexpected exit. To stop it, use `sudo systemctl disable --now meowkit.service`.

- Unit: `meowkit.service`
- Description: `MeowKit Background Workload`
- Tor is a required dependency; the installer detects the active distribution unit (`tor@default.service` or `tor.service`) and binds the miner to that exact unit.
- Service stdout/stderr are sent to the systemd journal under `meowkit`; inspect with `sudo journalctl -u meowkit.service`.
- The service remains visible and manageable through systemd.

## Huge pages

The installer dynamically attempts to reserve 1 GiB pages first and 2 MiB pages from the remaining shared RAM budget. It does not edit bootloader configuration. Dynamic 1 GiB allocation may fail due to physical-memory fragmentation; actual counts are read back and reported in verbose mode. A reboot-time reservation may be needed on some systems.

## 2.0.4 fixes\n\n- `--repair` is now accepted by the command-line parser.\n- Proxmox's 50% CPU default no longer overrides an explicitly selected CPU percentage.\n- Missing prerequisites are installed whether Tor was already present or not.\n- Tor connectivity checks now verify the Tor Project API's `IsTor` result, not merely an HTTP response.\n- Uninstall uses a strict marker/directive pair before removing the managed Tor listener.\n- Miner output is available in the systemd journal for troubleshooting.\n\n## Safety notes

- The configured wallet is the public wallet address supplied by the project owner.
- `/etc/tor/torrc` is backed up before editing. If validation fails, the previous configuration is restored. Uninstall removes the SOCKS listener only when the exact MeowKit marker is immediately followed by its exact directive; edited or unrelated lines are preserved.
- Existing Tor gateway and SSH settings are not intentionally modified.
- Uninstall removes MeowKit files and service only; it does not uninstall Tor or remove unrelated settings.
- This initial release targets x86_64 Debian/Ubuntu/Proxmox systems.
