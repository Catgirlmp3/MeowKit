# MeowKit 2.1.0

MeowKit is a Linux-only setup and service manager for an XMRig workload connected to MoneroOcean through a local Tor SOCKS5 proxy. It configures the miner, systemd service and supported CPU/memory optimisations for you.

This guide walks through a fresh Ubuntu Server installation, explains the installer's choices, and shows how to check, monitor, repair and remove the service.

## Before you start

### Supported systems

- x86_64 Debian, Ubuntu Server or Proxmox VE
- systemd and APT
- Root/sudo access
- Internet access for the initial package installation

The examples below use Ubuntu Server 24.04 LTS in a VirtualBox VM. The same commands apply to a compatible physical Linux machine.

### Example virtual machine

The walkthrough assumes:

| Setting | Example |
|---|---|
| Host | Windows 11 desktop |
| Guest | Ubuntu Server 24.04 LTS |
| Guest memory | 8 GiB |
| Virtual CPUs | 4 |
| VirtualBox paravirtualisation | KVM |

These are example values, not minimum requirements. Give the VM enough memory and CPU for Ubuntu itself as well as the mining workload. Avoid overcommitting the host.

### A couple of important notes

- **Do not manually reserve huge pages before installing.** MeowKit calculates a safe memory budget, attempts three 1 GiB RandomX pages per NUMA node when the kernel permits runtime reservation, then uses 2 MiB pages for the fallback. Some kernels require 1 GiB pages to be reserved at boot; MeowKit does not modify GRUB or reboot automatically.
- **Do not disable `systemd-oomd` as a routine setup step.** That is not required by MeowKit and can make memory pressure less manageable. If the VM runs out of memory, reduce the miner's resource allocation or give the VM more RAM instead.
- Tor routes the miner's pool connection through a Tor exit relay. The pool does not receive your normal public IP from that connection, but Tor is not a guarantee of anonymity and the exit relay's IP is visible to the destination.
- Virtual machines may not expose the CPU's MSR interface. MeowKit attempts to load MSR support where available and continues if the hypervisor or kernel blocks it.
- Huge-page allocation can be limited by available memory and fragmentation. A successful installer run does not mean every requested page was necessarily reserved; check the status and service logs.

## 1. Prepare Ubuntu

Sign in to the Ubuntu Server console, then update the package index and install Git:

```bash
sudo apt update
sudo apt upgrade -y
sudo apt install -y git
```

Git is needed to retrieve the repository. MeowKit installs its own runtime prerequisites, including Tor and the tools it needs, during setup.

You do not need to add manual `vm.nr_hugepages` settings to `/etc/sysctl.conf`. MeowKit attempts runtime 1 GiB page allocation and calculates the 2 MiB fallback automatically.

## 2. Download MeowKit

Clone the repository and enter its directory:

```bash
git clone https://github.com/Catgirlmp3/MeowKit.git
cd MeowKit
```

The repository's installer is already marked executable. If you downloaded a source archive that did not preserve executable permissions, you can restore the permission with:

```bash
chmod +x meowkit.sh
```

## 3. Run the installer

Start the interactive installer as root:

```bash
sudo ./meowkit.sh
```

The menu offers:

1. **Recommended installation** — detects the system and applies the default resource settings.
2. **Custom installation** — lets you enter any supported CPU allocation (10–100%), huge-page RAM budget (10–90%), VM CPU reduction (0–90%), and schedule settings. These are numeric inputs, not fixed presets.
3. **Repair installation** — checks and restores MeowKit-managed components.
4. **Uninstall MeowKit** — removes the managed miner and service.
5. **Exit** — leaves the system unchanged.

For a first installation, choose the recommended option unless you have a reason to tune the limits. The recommended baseline CPU allocation is 75%; the default huge-page budget is 75% of memory remaining after host and running-guest reserves. The default adaptive profile reduces the miner's selected thread count by 50% whenever at least one Proxmox VM or LXC container is running. The scheduler checks guest state every 15 seconds.

On the example 4-vCPU VM, a 75% CPU setting works out to a three-thread miner allocation and a systemd CPU quota based on all four virtual CPUs. Actual performance depends on the host's available CPU time and other workloads.

For a non-interactive installation, use:

```bash
sudo ./meowkit.sh --install --verbose
```

Use `--quiet` for minimal output or `--verbose` for detailed progress.

### What the installer configures

During installation, MeowKit:

- Installs missing prerequisites and configures Tor's local SOCKS5 listener on `127.0.0.1:9050`.
- Starts Tor and checks the Tor Project verification endpoint for `IsTor: true`.
- Downloads the pinned XMRig release through Tor and verifies its SHA-256 digest before installing it.
- Detects available logical CPUs and calculates the miner thread count and systemd CPU quota.
- Calculates a memory budget with a 2 GiB host reserve and Proxmox running-guest memory reservations; attempts three 1 GiB pages per NUMA node, then reserves 2 MiB pages as a fallback.
- Loads the MSR module where supported, enables the live `msr.allow_writes` parameter when exposed, and verifies read access with a non-destructive `rdmsr` probe.
- Creates a local-time mining schedule (default 08:00–16:00 at 40% of the configured baseline thread count, baseline allocation outside that window) and installs a systemd timer that checks it every 15 seconds.
- Monitors running Proxmox VMs and LXC containers. When guest state changes, MeowKit stops the miner, recalculates huge-page reservations against running guest memory, updates the XMRig configuration and systemd CPU quota, reloads systemd, then restarts and verifies the miner.
- Applies the configured VM CPU reduction to the current scheduled/baseline thread count while any guest is running. When all guests stop, the original baseline/schedule profile is restored automatically.
- Writes the miner configuration and creates `meowkit.service` with an explicit `--threads=N` setting, graceful SIGTERM shutdown and systemd restart recovery.
- Enables the service and schedule timer at boot and starts the miner.

The miner service runs as root, as configured by this project. Miner traffic is configured to use the local Tor proxy, and the service has a pre-start Tor verification check. If that check fails, systemd will not launch the miner.

The initial APT package installation is a bootstrap exception: Tor must be installed before it can proxy the package installation itself.

## 4. Check that it is running

After installation, check the service:

```bash
sudo systemctl status meowkit.service
```

Look for `Active: active (running)`. The exact process ID, memory use, task count and start time will differ from machine to machine.

You can also use MeowKit's status command:

```bash
sudo ./meowkit.sh --status
```

It reports the active thread count, schedule/timer state, Tor service and exit verification, 2 MiB/1 GiB page reservations, and whether MSR is loaded with write permission and read access.

If the service is not active, do not assume the install succeeded just because the installer reached its final message. Read the logs in the next step to find the cause.

## 5. Watch the miner logs

Follow the live systemd journal:

```bash
sudo journalctl -u meowkit.service -f
```

This is the main place to inspect XMRig startup messages, pool connection attempts, accepted shares, errors and reported hashrate.

Useful alternatives:

```bash
# Show the most recent 100 log lines
sudo journalctl -u meowkit.service -n 100 --no-pager

# Show logs from the current boot
sudo journalctl -u meowkit.service -b --no-pager

# Stop following the live log
# Press Ctrl+C
```

A healthy session should show XMRig starting, connecting to the configured pool through the proxy, receiving jobs and reporting mining activity. Hashrate varies with CPU model, VM scheduling, memory configuration, RandomX initialisation and competing workloads.

Tor adds routing and network latency, but it is not accurate to assume that encryption itself causes a fixed hashrate reduction. Mining performance is primarily determined by CPU and memory performance.

## 6. Confirm it survives a reboot

MeowKit enables `meowkit.service` at boot. Reboot the guest:

```bash
sudo reboot
```

After signing in again, check:

```bash
sudo systemctl is-enabled meowkit.service
sudo systemctl status meowkit.service
sudo ./meowkit.sh --status
```

The service should be enabled and should start once the network and Tor are ready. Its pre-start check verifies Tor before XMRig launches.

## Everyday commands

Run these from the MeowKit repository directory unless the command is a standard systemd/journalctl command.

| Task | Command |
|---|---|
| Show MeowKit status | `sudo ./meowkit.sh --status` |
| Preview the selected thread count | `sudo ./meowkit.sh --schedule-dry-run` |
| Apply the current schedule immediately | `sudo ./meowkit.sh --schedule` |
| Repair the installation | `sudo ./meowkit.sh --repair --verbose` |
| Start the service | `sudo systemctl start meowkit.service` |
| Stop the service | `sudo systemctl stop meowkit.service` |
| Restart the service | `sudo systemctl restart meowkit.service` |
| Follow live logs | `sudo journalctl -u meowkit.service -f` |
| View recent logs | `sudo journalctl -u meowkit.service -n 100 --no-pager` |
| Check boot enablement | `sudo systemctl is-enabled meowkit.service` |

Repair preserves a valid installed XMRig binary, the existing worker identity and saved CPU/huge-page settings. It restores MeowKit-managed helpers, reapplies supported tuning, checks Tor, refreshes the managed configuration and restarts the service.

## Resource tuning explained

### CPU

The CPU percentage determines the baseline thread count and systemd CPU quota. MeowKit passes an explicit `--threads=N` value to XMRig, so a scheduled limit is an exact thread count rather than relying on XMRig's percentage-based `max-threads-hint`. The configured quota remains the baseline ceiling; the thread count controls the daytime reduction.

The configured CPU percentage is the baseline profile and is never overwritten by VM activity. When any Proxmox VM or LXC container is running, the scheduler applies the configured VM reduction to the currently selected baseline or scheduled thread count. For example, a 50% VM reduction halves the active mining thread count. When the final guest stops, MeowKit returns to the original baseline or scheduled count.

### Time-based mining schedule

The default schedule uses the machine's configured local timezone (`Europe/Dublin` by default): 8 threads from 08:00 up to (but not including) 16:00, then the detected baseline allocation for the rest of the day. A systemd timer checks the schedule and Proxmox guest state every 15 seconds and applies changes automatically. The timer does not restart a healthy miner on every check; it only restarts when the selected allocation changes or when the installation/repair process explicitly requests a refresh.

Edit `/etc/meowkit/schedule.conf` to change `DAY_START`, `DAY_END`, `DAY_PERCENT`, `SCHEDULE_ENABLED` or `TIMEZONE`. Edit `/etc/meowkit/resources.conf` to change `CPU_PERCENT`, `RAM_PERCENT` or `VM_CPU_REDUCTION_PERCENT`; run `sudo ./meowkit.sh --repair` to apply manually, or let the schedule timer apply guest-state changes. For a different local timezone, use its IANA name (for example `Europe/Dublin`). The controller uses the Linux machine's configured timezone, not a separate remote Windows clock.

Preview the next/current selection with `sudo ./meowkit.sh --schedule-dry-run`; apply the current selection immediately with `sudo ./meowkit.sh --schedule`.

### 1 GiB and 2 MiB huge pages

MeowKit calculates a safe memory budget after a 2 GiB host reserve and Proxmox running-guest reservations. It attempts three 1 GiB RandomX pages per NUMA node only when the full target fits inside that budget, then assigns the configured percentage of remaining memory to 2 MiB pages. When guest state changes, MeowKit stops XMRig and recalculates its managed page allocation. It tracks the page counts that existed before MeowKit first managed them, so it does not intentionally reclaim those pre-existing reservations. Kernel pages still in use by another process may not be releasable; check the logs if the requested reduction cannot be applied.

Some kernels only permit 1 GiB huge pages to be reserved at boot. MeowKit does not automatically alter GRUB/kernel command-line settings or reboot; in those environments it falls back to 2 MiB pages. For a small VM, leave enough RAM for the operating system and any other workloads.

### MSR

MeowKit loads the MSR module at boot, requests `allow_writes=on`, and explicitly attempts to set the live `/sys/module/msr/parameters/allow_writes` value when the kernel exposes it. It then performs a read-only `rdmsr` probe. A successful read does not guarantee that every write is permitted; Secure Boot/kernel lockdown and hypervisors can restrict access. MeowKit does not issue generic arbitrary WRMSR commands. XMRig handles CPU-specific RandomX MSR presets and restores the values it changes when it exits.

## Troubleshooting

### The service keeps restarting

Inspect the latest service logs:

```bash
sudo journalctl -u meowkit.service -n 150 --no-pager
```

Check Tor separately:

```bash
sudo systemctl status tor@default.service
sudo systemctl status tor.service
sudo ./meowkit.sh --status
```

Only one of the Tor unit names may exist on a given distribution. MeowKit detects the available unit during setup.

### Tor verification fails

Check that the Tor service is active, that the guest can reach the network, and that the local SOCKS5 listener is available on port 9050. A firewall, clock problem, captive portal or blocked Tor connection can prevent verification. MeowKit deliberately does not fall back to a direct miner connection.

### Huge pages are lower than expected

Memory fragmentation or insufficient free memory can prevent the kernel from reserving the full target. Check the current reservation:

```bash
cat /sys/kernel/mm/hugepages/hugepages-2048kB/nr_hugepages
```

Each page represents 2 MiB. Do not blindly force a larger number: leave memory for the operating system and any other VM workloads.

### MSR is unavailable in VirtualBox

This can be a hypervisor limitation rather than a MeowKit fault. Check `sudo /usr/local/sbin/meowkit-msr-enable`, `/sys/module/msr/parameters/allow_writes`, and whether `rdmsr -p 0 0x10` succeeds. Secure Boot/kernel lockdown or the hypervisor may still block MSR access; MeowKit safely continues without the optimisation.

### Repair the managed setup

If a helper, configuration or service unit is missing or damaged, run:

```bash
sudo ./meowkit.sh --repair --verbose
```

## Uninstall

Run the installer and choose the uninstall menu option, or execute the uninstall script directly:

```bash
sudo ./commands/uninstall.sh
```

Uninstall removes MeowKit's service, miner binary, helper scripts, MSR configuration and managed application configuration. It does not uninstall Tor or intentionally remove unrelated Tor, SSH, gateway or system settings.

## Supported scope

MeowKit targets x86_64 Debian, Ubuntu and Proxmox VE systems using systemd and APT. It is a Linux-only project; the separate Windows implementation is maintained elsewhere.
