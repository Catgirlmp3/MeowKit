# MeowKit 2.0.0

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

- Unit: `meowkit.service`
- Description: `MeowKit Background Workload`
- Tor is a required dependency; the installer detects the active distribution unit (`tor@default.service` or `tor.service`) and binds the miner to that exact unit.
- Service stdout/stderr are discarded; MeowKit does not create persistent application log files. systemd may still retain ordinary service lifecycle/audit metadata according to the host journal policy.
- The service remains visible and manageable through systemd.

## Huge pages

The installer dynamically attempts to reserve 1 GiB pages first and 2 MiB pages from the remaining shared RAM budget. It does not edit bootloader configuration. Dynamic 1 GiB allocation may fail due to physical-memory fragmentation; actual counts are read back and reported in verbose mode. A reboot-time reservation may be needed on some systems.

## Safety notes

- The configured wallet is the public wallet address supplied by the project owner.
- `/etc/tor/torrc` is backed up before editing. Uninstall removes only the MeowKit-managed SOCKS listener stanza and preserves unrelated Tor settings.
- Existing Tor gateway and SSH settings are not intentionally modified.
- Uninstall removes MeowKit files and service only; it does not uninstall Tor or remove unrelated settings.
- This initial release targets x86_64 Debian/Ubuntu/Proxmox systems.
