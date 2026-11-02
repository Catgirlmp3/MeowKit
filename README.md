# MeowKit 2.0.5

A Linux-only installer and service manager for XMRig and MoneroOcean, using a local Tor SOCKS5 proxy.

## Requirements

- Debian, Ubuntu, or Proxmox VE on x86_64
- Root access
- systemd and APT
- An active internet connection for the initial package bootstrap

## Install

\`\`\`bash
git clone https://github.com/Catgirlmp3/MeowKit.git
cd MeowKit
sudo ./meowkit.sh
\`\`\`

For non-interactive use:

\`\`\`bash
sudo ./meowkit.sh --install --verbose
sudo ./meowkit.sh --status
sudo ./meowkit.sh --repair
sudo ./meowkit.sh --help
\`\`\`

Quiet output is the default. Use \`--verbose\` for detailed progress.

## Runtime behaviour

- XMRig is managed by \`meowkit.service\` and runs as root.
- The service starts at boot and restarts after an unexpected exit.
- Miner traffic and MeowKit release downloads use the local Tor SOCKS5 listener at \`127.0.0.1:9050\`.
- The service refuses to start unless the Tor Project check endpoint confirms \`IsTor: true\`.
- There is no direct-connection fallback for miner traffic or release downloads.
- Initial APT package installation is the bootstrap exception: Tor must be installed before it can provide the proxy.
- Logs are available with \`sudo journalctl -u meowkit.service\`.

## Resource tuning

- CPU allocation is applied through XMRig's thread hint and systemd's CPU quota. The quota is calculated against total logical CPUs, not the already-rounded miner thread count.
- MeowKit dynamically allocates 2 MiB huge pages. It does not request 1 GiB pages or edit bootloader configuration.
- Huge-page budgeting uses physical RAM, a 2 GiB host safety reserve, and configured memory for running Proxmox guests. Existing huge-page reservations are not reduced.
- The 2 MiB allocation is retried before the miner starts, including after reboot.
- The MSR module is loaded automatically where supported, configured to permit writes where the kernel exposes that option, and loaded at boot.
- Kernel lockdown, unsupported CPUs, unavailable MSR devices, or memory fragmentation can prevent an optimisation from being applied. Mining can continue without unavailable optimisations.

## Repair and uninstall

\`--repair\` checks the installed XMRig binary, restores managed helpers, reapplies resource tuning, validates Tor, rewrites the managed miner configuration and systemd unit, then restarts the service. A valid installed XMRig binary and the existing worker identity are preserved.

Uninstall removes MeowKit's service, binary, helpers, and managed configuration. It does not uninstall Tor or remove unrelated Tor, SSH, gateway, or system settings.

## Supported scope

MeowKit targets x86_64 Debian, Ubuntu, and Proxmox VE systems using systemd and APT. Windows support is maintained separately and is not part of this repository.
