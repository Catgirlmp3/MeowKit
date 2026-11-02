# MeowKit 2.0.5

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

1. **Recommended installation** — detects the system and applies the default resource settings.
2. **Custom installation** — lets you choose CPU allocation and the huge-page RAM budget.
3. **Repair installation** — checks and restores MeowKit-managed components.
4. **Uninstall MeowKit** — removes the managed miner and service.
5. **Exit** — leaves the system unchanged.

For a first installation, choose the recommended option unless you have a reason to tune the limits. The default CPU allocation is 75%; the default huge-page budget is 75% of the memory left after the safety reserves described below.

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
- Requests 2 MiB huge pages using a memory budget that keeps a 2 GiB host reserve and, on Proxmox, accounts for configured memory assigned to running guests.
- Loads the MSR kernel module where supported and configures it to load at boot.
- Writes the miner configuration and creates `meowkit.service`.
- Enables the service at boot and starts it.

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

The service should be enabled and should start once the network and Tor are ready. Its pre-start check verifies Tor before XMRig launches.

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

Repair preserves a valid installed XMRig binary, the existing worker identity and saved CPU/huge-page settings. It restores MeowKit-managed helpers, reapplies supported tuning, checks Tor, refreshes the managed configuration and restarts the service.

## Resource tuning explained

### CPU

The CPU percentage controls XMRig's thread hint and the systemd CPU quota. The quota is calculated from the total number of logical CPUs, rather than from the rounded-down miner thread count. This helps keep the requested percentage consistent on systems where the thread count does not divide evenly.

On Proxmox hosts with running guests, MeowKit uses a more conservative default CPU allocation unless you explicitly choose a custom value.

### 2 MiB huge pages

MeowKit allocates standard 2 MiB huge pages. It does not request 1 GiB pages or permanently change bootloader settings.

The memory budget is calculated from physical RAM, less a 2 GiB host reserve and (on Proxmox) the configured memory of running VMs and containers. The selected percentage is applied to the remaining budget. Existing huge-page reservations are not reduced.

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

Check that the Tor service is active, that the guest can reach the network, and that the local SOCKS5 listener is available on port 9050. A firewall, clock problem, captive portal or blocked Tor connection can prevent verification. MeowKit deliberately does not fall back to a direct miner connection.

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
