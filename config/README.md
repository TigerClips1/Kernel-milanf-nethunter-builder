# Kernel Configurations

This directory contains the seed configuration and feature fragments used by
`scripts/05_configure.sh`. The final, dependency-resolved kernel configuration
is generated at `out/kernel/.config`; edit the source files here, not that
generated file.

## Files

| File | Role |
|---|---|
| `milanf_device.config` | Full Linux 5.4.302 config dump from the target milanf device. It is the preferred seed when present. It is generated from a running kernel and should not be hand-edited. |
| `milanf_nethunter.config` | NetHunter feature fragment: wireless, USB, CAN, SDR, NFS, networking, and related options. |
| `milanf_kernelsu.config` | KernelSU Next feature fragment. KernelSU source integration and 5.4 compatibility hooks are handled separately by `scripts/04_integrate_ksu.sh` and `patches/kernelsu/`. |

## Merge Order

When `milanf_device.config` exists, configuration starts from that file. The
LineageOS common and milanf vendor fragments are added when available, followed
by `milanf_nethunter.config` and then `milanf_kernelsu.config`.

If the device config is absent, the build starts from the Motorola
`vendor/holi-qgki_defconfig`, then merges the same vendor, NetHunter, and
KernelSU fragments. The script refuses a non-QGKI base for this device.

Later fragments override earlier values for the same symbol. The hostname and
local version in the NetHunter fragment intentionally override the stock
device values. Avoid repeating the same assignment within one fragment unless
an override is deliberate. Kconfig's `olddefconfig` resolves dependencies, so
the final `.config` can differ from a requested fragment value if the symbol is
unavailable or its dependencies are not enabled.

The CAN module settings are also enforced by the configure/build scripts. The
HLCAN symbol is case-sensitive and spelled `CONFIG_hlcan`; its Kconfig entry and
the ISO-TP entry are added by `patches/kernel/004-can-driver-integration.patch`.
Step 02 fetches those CAN driver submodules and stages the ISO-TP UAPI header.

## Updating and Checking

1. Add or change an option in the appropriate fragment. Keep device-specific
   hardware settings in the device baseline, NetHunter features in the
   NetHunter fragment, and KernelSU feature flags in the KernelSU fragment.
2. After source cloning and patching, clear any completion markers and rerun
   configuration with `bash build.sh --clean` followed by
   `bash build.sh --step=configure`. For a normal complete build, use
   `bash build.sh`.
3. Inspect the resolved option in `out/kernel/.config`, for example:
   `grep -E '^(CONFIG_CAN=|CONFIG_hlcan=|CONFIG_CAN_ISOTP=)' out/kernel/.config`.

The supplied device config is checked against `KERNEL_VERSION` before use. If
refreshing it, pull `/proc/config.gz` or `.config` from the matching milanf
kernel and preserve its Linux version header. Do not use a config from a
different device or kernel version as the seed.