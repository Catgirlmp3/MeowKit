# MeowKit 2.0.7

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

- **Do not manually reserve huge pages before installing.** MeowKit calculates and requests 2 MiB huge pages itself, then retries the allocation before the miner starts and at service startup after reboot.
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

Git is needed to retrieve the repository and the pinned XMRig source. MeowKit installs its own build prerequisites, including the compiler, CMake, libuv and hwloc development headers, during setup.

You do not need to add manual `vm.nr_hugepages` settings to `/etc/sysctl.conf`. MeowKit manages its 2 MiB huge-page allocation.

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

1. **Recommended** — 75% baseline CPU allocation.
2. **Shared host** — 50% baseline CPU allocation.
3. **Maximum** — 100% baseline CPU allocation.
4. **Custom** — enter any CPU percentage (1–100%), huge-page RAM budget (1–100%), VM CPU reduction (0–90%), and time-based schedule settings.
5. **Repair installation** — restores managed components while preserving the saved worker name and resource profile.
6. **Uninstall MeowKit** — removes the managed miner, watcher and services.
7. **Exit** — leaves the system unchanged.

Custom mode is genuinely numeric rather than a set of CPU presets. The default schedule is 08:00–16:00 at 40% of the configured baseline thread count, with the baseline allocation outside that window. The default VM policy reduces the currently selected mining thread count by 50% whenever any Proxmox VM or LXC container is running.

The 100% profile removes MeowKit's CPU headroom allowance. It can make the guest less responsive and can compete with other VMs or host workloads; use it when maximum mining throughput is the priority.

For a first installation, choose the recommended option unless you have a reason to tune the limits. The baseline CPU allocation defaults to 75%. Guest activity does not overwrite that baseline: the adaptive resource manager applies the configured reduction while Proxmox guests are running, then restores the baseline/schedule when they stop. A VirtualBox guest cannot see other VMs running on its Windows host; use **Shared host (50%)** to choose a lower baseline in that situation.

For a non-interactive installation, use:

```bash
sudo ./meowkit.sh --install --verbose
```

For a Windows-hosted VirtualBox guest sharing resources with another VM:

```bash
sudo ./meowkit.sh --install --vm-mode shared
```

You can also set arbitrary values with `--cpu-percent N`, `--ram-percent N`, `--vm-reduction N`, `--day-percent N`, `--day-start HH:MM` and `--day-end HH:MM`, or pass `--threads N`. The systemd quota is calculated as `N × 100%`, so 18 threads produce `CPUQuota=1800%`.

Use `--quiet` for minimal output or `--verbose` for detailed progress.

### What the installer configures

During installation, MeowKit:

- Installs missing prerequisites and configures Tor's local SOCKS5 listener on `127.0.0.1:9050`.
- Installs Tor as the first APT package operation, before refreshing package indexes or installing the remaining prerequisites. It prefers already-cached Debian indexes, then refreshes and retries only if an installation fails. This avoids making an unrelated APT source authentication error block a Tor install that can already be satisfied from the Debian package cache. It then validates the Tor configuration, enables the available Tor systemd unit, and tests the SOCKS5 route. Slow Tor bootstrap is non-fatal; the miner retries through the proxy.
- Fetches the pinned XMRig v6.26.0 source revision directly from GitHub (not through Tor), patches the source donation defaults/minimum to 0%, compiles it locally, and installs the resulting binary. Tor is still required and strictly verified for mining-pool traffic.
- Detects CPUs available to the current process (respecting VM/cgroup limits), calculates the miner thread count, and sets `CPUQuota` to 100% per miner thread.
- Calculates 2 MiB and optional 1 GiB huge pages from the configured RAM budget, a host safety reserve, running Proxmox guest memory and the selected thread count.
- Installs an adaptive resource timer that checks schedule and Proxmox VM/LXC state every 15 seconds. When guest state or the schedule changes, it stops XMRig, adjusts the managed huge-page reservation, writes the new thread count and systemd CPU quota, reloads systemd, restarts the miner and verifies the new process.
- Loads the MSR kernel module where supported and configures it to load at boot.
- Writes the miner configuration and creates `meowkit.service`.
- Enables the service at boot and starts it.

MeowKit builds XMRig locally from the pinned upstream v6.26.0 source. Its `src/donate.h` defaults and minimum are patched to 0 before compilation, and the generated configuration explicitly sets `donate-level` and `donate-over-proxy` to 0. This is a source modification, not an unsupported runtime override. The upstream GPL-3.0 license and copyright notices remain in the source checkout.

The service runs as root (systemd's default when no `User=` is specified). Its `ExecStart` uses `/usr/local/bin/meowkit-xmrig --config=/etc/meowkit/config.json --threads=N`; it does not depend on the installer's `$HOME`, so `/root` versus `/home/USERNAME` does not change the config path. The service requests Tor at boot but does not order miner startup behind Tor's systemd readiness notification. If Tor is late after reboot, XMRig starts and retries through the SOCKS5 proxy instead of blocking VM boot. It never falls back to a direct pool connection.

The initial APT package installation is a bootstrap exception: Tor is installed first using the currently available package indexes. Only if that fails does MeowKit refresh APT indexes and retry. The remaining prerequisites are installed afterwards, with the same install-first/refresh-on-failure approach.

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

It reports service/Tor state, huge-page reservations, baseline CPU/RAM settings, VM reduction policy, schedule, adaptive timer state and the currently selected thread count.

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

The service should be enabled and start independently of Tor's bootstrap timing. If Tor is still connecting, XMRig retries after a 30-second restart delay.

## Everyday commands

Run these from the MeowKit repository directory unless the command is a standard systemd/journalctl command.

| Task | Command |
|---|---|
| Show MeowKit status | `sudo ./meowkit.sh --status` |
| Repair the installation | `sudo ./meowkit.sh --repair --verbose` |
| Start the service | `sudo systemctl start meowkit.service` |
| Stop the service | `sudo systemctl stop meowkit.service` |
| Restart the service | `sudo systemctl restart meowkit.service` |
| Follow live logs | `sudo journalctl -u meowkit.service -f` |
| View recent logs | `sudo journalctl -u meowkit.service -n 100 --no-pager` |
| Check boot enablement | `sudo systemctl is-enabled meowkit.service` |

Repair preserves a valid XMRig binary and worker identity. It restores helpers, recalculates CPU quota and huge pages from current VM resources, attempts Tor verification without making it a boot prerequisite, validates JSON before replacing it, and refreshes the service unit.

## Resource tuning explained

### Adaptive Proxmox VM profile

The resource watcher polls every 15 seconds for running QEMU VMs (`qm list`) and LXC containers (`pct list`). It applies the configured VM reduction to whichever thread count is currently selected by the time schedule. For example, a 50% reduction halves a 12-thread baseline to 6 threads; if the daytime schedule already reduced that to 5 threads, the VM profile halves the 5-thread value instead (with a minimum of one thread).

When a guest starts or stops, MeowKit stops XMRig, recalculates the huge-page budget using the configured memory of all running guests and a host reserve, updates the runtime thread count and systemd CPUQuota drop-in, runs `systemctl daemon-reload`, restarts the miner and verifies its process. When the last guest stops, it restores the configured baseline or current scheduled allocation. The saved baseline is not rewritten by VM activity.

The watcher can only detect guests on a Proxmox host where `qm` and/or `pct` are available. A VirtualBox guest cannot inspect other VMs on its Windows host. Huge-page pools may refuse to shrink if pages are still in use by another process; MeowKit logs that condition and continues with the pages the kernel makes available.

### CPU

The default profile allocates 75% of available CPUs; the shared-host profile allocates 50%; the maximum profile allocates 100%. Custom mode accepts any whole-number CPU percentage from 1 to 100. CPU detection respects the CPUs available inside the guest. With `--threads N`, MeowKit uses that count and sets `CPUQuota=N×100%`.

On a Proxmox host, the adaptive watcher detects running guests and applies the configured VM reduction. A VirtualBox guest on Windows cannot inspect other VMs on the Windows host, so use `--vm-mode shared` to choose a lower baseline when another VM is active.

### 2 MiB huge pages

MeowKit calculates its huge-page target from physical RAM, a host reserve (at least 2 GiB and normally 20% of RAM), the configured memory of running Proxmox guests, the RandomX dataset requirement and selected thread count. The RAM percentage limits the safe budget. It attempts one 1 GiB page when the kernel exposes that interface and enough memory is available, then uses 2 MiB pages for the remainder. It tracks the pre-existing page counts and adjusts only the allocation managed by MeowKit. 1 GiB pages are optional; MeowKit does not alter GRUB or require a reboot.

For a small VM, leave enough memory for Ubuntu and other services. If the guest becomes sluggish or reports memory pressure, use the custom installation option to lower the huge-page budget or increase the VM's assigned RAM.

### MSR

MeowKit configures the MSR module to load at boot and enables write support where the running kernel exposes that setting. Some kernels, CPUs and hypervisors restrict MSR access. In those environments, the optimisation may be unavailable; MeowKit reports the limitation and continues.

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

Check that the Tor service is active, that the guest can reach the network, and that the local SOCKS5 listener is available on port 9050. A firewall, clock problem, captive portal or blocked Tor connection can delay verification. MeowKit deliberately does not fall back to a direct connection; systemd retries the miner instead of making Tor verification a boot dependency.

### Huge pages are lower than expected

Memory fragmentation or insufficient free memory can prevent the kernel from reserving the full target. Check the current reservation:

```bash
cat /sys/kernel/mm/hugepages/hugepages-2048kB/nr_hugepages
```

Each page represents 2 MiB. Do not blindly force a larger number: leave memory for the operating system and any other VM workloads.

### MSR is unavailable in VirtualBox

This can be a hypervisor limitation rather than a MeowKit fault. The guest may not be allowed to access the host CPU's MSR interface. MeowKit can continue without this optimisation.

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
