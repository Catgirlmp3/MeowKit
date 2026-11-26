# Bundled XMRig build

MeowKit bundles a Linux x86_64 XMRig executable built from the upstream source.

- Upstream: https://github.com/xmrig/xmrig
- Version: v6.26.0
- Exact source commit: `b2ca72480c58d197e18c885d9fc1a0c8d517e60a`
- License: GNU GPL-3.0-or-later; see [LICENSE](LICENSE)
- MeowKit modification: [zero-donation.patch](zero-donation.patch), which sets both `kDefaultDonateLevel` and `kMinimumDonateLevel` to zero.
- Build options: Release, hwloc enabled, TLS/OpenCL/CUDA disabled, MSR and assembly enabled.

The complete corresponding upstream source is available at the exact commit above. Apply the included patch to reproduce the MeowKit zero-donation source changes. The CI workflow pins and verifies that commit before compiling the bundled executable.
