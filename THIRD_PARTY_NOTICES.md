# Third-party notices

This project coordinates a number of independently developed tools and research projects. This file is an attribution index, not a replacement for the license text distributed with any dependency.

When source or binaries are vendored, packaged, mirrored, or released with this repository, the corresponding upstream license and copyright notices must be retained with that component.

## Original ICH project

- **ICH_A12_plus_Ramdisk / new_ramdisk**
  - Project: `Pa7r0n/ICH_A12_plus_Ramdisk`
  - Author/contact: `@Official_I_C_H`
  - Role: upstream A12/A13 ramdisk builder and boot orchestration
  - License: see the upstream `LICENSE` and `NOTICE`

## BootROM / boot-chain research

- **usbliter8**
  - Project credited upstream to Paradigm Shift
  - Role: RP2350-based BootROM exploit used to obtain the pwned DFU state
  - Source: `prdgmshift/usbliter8`
  - License: retain the license distributed by that project

- **usbliter8ra1n / standalone patchfinders**
  - Credited upstream to Leeksov
  - Role: iBoot, kernel, SPTM/TXM patching research and reference boot flows
  - License: retain the license distributed by the relevant upstream source

- **Duy Tran**
  - Credited upstream for TXM policy field research

- **Matthew Pierson / vphone-cli**
  - Credited upstream for FirmwarePatcher / ramdisk-build reference work

## Ramdisk / jailbreak infrastructure

- **palera1n / checkra1n ecosystem**
  - Role: ramdisk, trustcache and SSHRD infrastructure/reference work

- **SSHRD_Script — Nathan / verygenericname**
  - Role: source/reference for the `ssh.tar.gz` RestoreRamDisk payload used by the upstream project

- **TrollStore — opa334**
  - Role: helper binaries included by the upstream SSH payload

## Firmware and host tooling

- **blacktop/ipsw**
  - Role: Apple firmware discovery/extraction tooling
  - Source: `blacktop/ipsw`

- **img4 / trustcache / pzb / irecovery / libusb / usbliter8_boot**
  - The upstream project notes that Darwin host binaries under `tools/darwin/` originate from the Spironolactone / palera1n-adjacent toolchain.
  - The WSL2 port builds or wraps Linux-native equivalents where practical.
  - Each component retains its own upstream copyright and license.

- **lzfse**
  - Role: compression support needed by the IMG4 toolchain
  - The WSL2 build contains compatibility handling for modern CMake and the static library layout expected by dependent code.

- **ibootim**
  - Role: iBoot image conversion/manipulation
  - The Linux port contains compatibility work for host differences such as BSD/macOS-specific error constants.

## WSL2 / Linux host infrastructure

- **Microsoft WSL2 Linux kernel**
  - Role: WSL2 guest kernel; during development a matching custom kernel was used to support the required external APFS module and USB/IP pieces
  - Source: Microsoft's WSL2 Linux kernel repository
  - License: retain the kernel source tree's license and notices

- **usbipd-win**
  - Role: attach the physical Apple USB device from Windows to WSL2
  - Source: Microsoft's `usbipd-win` project
  - License: retain the upstream project's license

- **linux-apfs-rw / linux-apfs**
  - Role: experimental writable APFS access used only on host-side disposable RestoreRamDisk build images during the WSL2 port workflow
  - Source: `linux-apfs/linux-apfs-rw`
  - This component is not relicensed by this repository. Any distributed source/module must carry its upstream license and notices.

- **apfsprogs**
  - Role: APFS userspace utilities used during development and filesystem experiments
  - License: retain the upstream project's license

## Distribution policy

The preferred release model for this port is:

1. keep this repository's own scripts and documentation under its MIT license;
2. fetch and build third-party source from its canonical upstream repository where practical;
3. pin known-good revisions for reproducibility;
4. include required license files when redistributing third-party binaries or source;
5. avoid treating the repository-level MIT license as if it relicensed vendored dependencies.

If a dependency's redistribution terms are unclear, do not bundle it into a release until those terms have been reviewed.
