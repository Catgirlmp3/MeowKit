# MeowKit 2.0.6

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

Git is needed to retrieve the repository. MeowKit installs its own runtime prerequisites, including Tor and the tools it needs, during setup.

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

1. **Recommended — 75% CPU allocation.**
2. **Shared VM — 50% CPU allocation** when another VM or workload shares the host.
3. **Custom** — choose 50% or 75% CPU allocation and the huge-page RAM budget.
4. **Repair installation** — checks and restores MeowKit-managed components.
5. **Uninstall MeowKit** — removes the managed miner and service.
6. **Exit** — leaves the system unchanged.

For a first installation, choose the recommended option unless you have a reason to tune the limits. The default CPU allocation is 75%. If running Proxmox guests are detected, automatic mode drops to 50%. A VirtualBox guest cannot reliably see other VMs running on its Windows host, so choose **Shared VM (50%)** when another VM is active. MeowKit never allocates less than 50% of the CPUs visible inside the guest.

For a non-interactive installation, use:

```bash
sudo ./meowkit.sh --install --verbose
```

For a Windows-hosted VirtualBox guest sharing resources with another VM:

```bash
sudo ./meowkit.sh --install --vm-mode shared
```

You can also choose a profile with `--cpu-percent 50` or `--cpu-percent 75`, or pass `--threads N`. Explicit thread counts must be at least 50% of the guest's available logical CPUs. The systemd quota is calculated as `N × 100%`, so 18 threads produce `CPUQuota=1800%`.

Use `--quiet` for minimal output or `--verbose` for detailed progress.

### What the installer configures

During installation, MeowKit:

- Installs missing prerequisites and configures Tor's local SOCKS5 listener on `127.0.0.1:9050`.
- Attempts Tor verification during installation; a slow bootstrap is non-fatal.
- Downloads the pinned XMRig release through Tor and verifies its SHA-256 digest before installing it.
- Detects CPUs available to the current process (respecting VM/cgroup limits), calculates the miner thread count, and sets `CPUQuota` to 100% per miner thread.
- Calculates 2 MiB huge pages from available RAM, a safety reserve and selected thread count; it also attempts optional 1 GiB pages when exposed by the kernel.
- Loads the MSR kernel module where supported and configures it to load at boot.
- Writes the miner configuration and creates `meowkit.service`.
- Enables the service at boot and starts it.

The service runs as root (systemd's default when no `User=` is specified). Its `ExecStart` uses `/usr/local/bin/meowkit-xmrig --config=/etc/meowkit/config.json --threads=N`; it does not depend on the installer's `$HOME`, so `/root` versus `/home/USERNAME` does not change the config path. The service is ordered after Tor but does not use `Requires=` or a pre-start Tor check. If Tor is late after reboot, XMRig retries through systemd instead of blocking VM boot.

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

It reports the service state, whether it is enabled at boot, Tor service state, Tor exit verification, 2 MiB huge-page reservation and whether the MSR module is loaded.

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

### CPU

The default profile allocates 75% of available CPUs; the shared-VM profile allocates 50%. 50% is the hard minimum. CPU detection respects the CPUs available inside the guest. With `--threads N`, MeowKit uses that count (subject to the 50% minimum) and sets `CPUQuota=N×100%`.

Proxmox guests can be detected from the host. A VirtualBox guest on Windows cannot inspect other VMs on the Windows host, so use `--vm-mode shared` when another VM is active.

### 2 MiB huge pages

MeowKit calculates its 2 MiB huge-page target from `MemAvailable`, a safety reserve (at least 1 GiB and normally 20% of RAM), the RandomX dataset requirement and configured thread count. The RAM percentage limits the safe budget. It also attempts one 1 GiB page when the kernel exposes that interface and enough memory is available. 1 GiB pages are optional; MeowKit does not alter GRUB or require a reboot.

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
