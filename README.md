# ICH_A12_plus_Ramdisk-WSL2

WSL2/Linux port of [@Official_I_C_H](https://github.com/Pa7r0n)'s ICH A12/A13 SSH ramdisk tooling.

- **Original project:** `Pa7r0n/ICH_A12_plus_Ramdisk` / `@Official_I_C_H`
- **WSL2/Linux port:** `@SpaceDudem` (`spacedudem` / `erktheerk`)
- **License:** MIT for this repository's code; third-party components retain their own licenses
- **Status:** active bring-up; host-side WSL2 bootchain is working through `bootx`, final A13 XNU/ramdisk handoff is still being validated

> This is a port, not a rewrite of the underlying exploit or patchfinder research. Credit for those components remains with their original authors.

## What this project does

The upstream project is designed around a macOS/Darwin host. This port adapts the host-side workflow so an A12/A13 SSH ramdisk can be built and driven from **Windows 11 + WSL2 Linux**.

The port replaces or adapts the macOS-specific pieces with:

- native Linux builds of the required host tools
- `usbipd-win` for Windows-to-WSL Apple USB passthrough
- a WSL2 kernel with the USB/IP pieces required by `usbipd-win`
- `linux-apfs-rw` for writable APFS access during RestoreRamDisk modification
- Linux-native ramdisk injection without `hdiutil` or `diskutil`
- udev permissions for non-root access to Apple DFU/Recovery USB devices
- WSL-specific build, status, USB and boot orchestration

## Current development status

### Confirmed working on WSL2

- Linux toolchain build and verification
- `irecovery`
- `pzb`
- `img4`
- `gtar`
- `trustcache`
- `jq`
- `usbliter8ctl`
- `usbliter8_boot`
- `iproxy`
- `sshpass`
- `ibootim`
- `mkapfs`
- `ipsw`
- writable APFS inside WSL2
- Windows `usbipd` → WSL2 Apple USB passthrough
- Apple DFU mode (`05ac:1227`)
- usbliter8 pwned DFU detection
- patched iBoot upload from WSL2
- DFU → patched iBoot Recovery transition (`05ac:1281`)
- signed logo upload / `setpicture`
- RestoreSEP upload
- PMP/AOP/ANE/AVE/ISP/GFX/SIO firmware uploads
- DeviceTree upload
- trustcache upload
- modified RestoreRamDisk upload
- patched kernelcache upload
- boot-args injection
- `bootx` command delivery

### Current blocker

On the current A13 test device, the direct-iBEC chain accepts `bootx` but remains in iBoot Recovery instead of entering the patched XNU/SSH ramdisk environment.

This means the WSL2 host transport and payload-delivery path are operational. The remaining work is the device-side handoff after `bootx`. The next validation path is the alternate **iBSS → iBEC** chain already supported by the upstream project.

The repository should therefore be considered **development / bring-up quality**, not a finished one-command release yet.

## Test platform

Current WSL2 bring-up has been performed with:

```text
Host:       Windows 11 + WSL2
Distro:     Kali Linux
Device:     iPhone 11
Product:    iPhone12,1
Board:      n104ap
SoC:        Apple A13 / CPID 0x8030
iOS:        26.0.1 / 23A355
Exploit:    usbliter8
```

Current custom WSL kernel during development:

```text
6.18.33.2-microsoft-standard-WSL2+
```

The exact kernel version is not intended to be a permanent requirement. A reproducible packaging/install strategy will be documented as the port is finalized.

## Architecture

```text
Windows 11
    │
    ├── usbipd-win
    │
    ▼
WSL2 / Linux
    │
    ├── WSL kernel
    │    ├── USB/IP VHCI support
    │    └── external linux-apfs-rw module
    │
    ├── irecovery / libusb
    ├── usbliter8ctl
    ├── img4 / trustcache / ibootim / pzb
    ├── APFS RestoreRamDisk modification
    └── ICH build + boot orchestration
             │
             ▼
       A12/A13 device
```

## Major porting problems already solved

### macOS-only RestoreRamDisk workflow

The upstream workflow relies on Darwin facilities such as `hdiutil` and `diskutil`. WSL2 has neither.

An early Linux implementation attempted to mount Apple's stock RestoreRamDisk, copy its logical contents into a newly created APFS image, and inject SSH there. That failed because the stock Apple image is far more space-efficient than the reconstructed Linux-generated image.

Measured during bring-up:

```text
Stock image bytes:        ~188 MiB
Logical mounted contents: ~734 MiB
Original free space:      ~29 MiB
Original SSH payload:     ~39 MiB unpacked
```

A 1 GiB reconstructed APFS image proved that the Linux APFS code could perform the copy and injection, but the resulting image exceeded the bootchain ramdisk size limit.

The working approach preserves Apple's original APFS image and injects directly into it through `linux-apfs-rw`.

### SSH payload slimming

The stock image did not have enough free space for the full upstream SSH payload. Nonessential rescue-environment data was removed from the injected copy, including localization data, nano syntax definitions, the `file` magic database, and unnecessary terminfo entries.

Result during testing:

```text
RestoreRamDisk size: 188 MiB
Free before:          ~29 MiB
Free after:           ~4.6 MiB
Direct injection:     successful
```

### Custom WSL kernel + USB/IP

Adding writable APFS support exposed a second requirement: `usbipd-win` still needs the WSL kernel's USB/IP host pieces. The development kernel/module set includes the relevant USB core and VHCI components so Apple devices can be attached into WSL.

### Linux `usbliter8ctl` wrapper bug

The WSL port exposes `tools/linux/usbliter8ctl` as a Bash wrapper around the upstream Python implementation. An early boot path incorrectly executed that Bash wrapper through `python3`, producing a Python `SyntaxError` on `set -Eeuo pipefail` and then incorrectly continuing as if boot had succeeded.

The caller now executes the wrapper directly and propagates failures correctly.

That fix produced the first confirmed WSL-side transition from usbliter8 pwned DFU into patched iBoot Recovery on the A13 test device.

## Repository layout

The intended final layout is:

```text
.
├── README.md
├── LICENSE
├── NOTICE
├── THIRD_PARTY_NOTICES.md
├── docs/
│   └── PORTING.md
├── scripts/
├── tools/
└── ich-wsl2-port.sh
```

Generated firmware, bootchains, kernel build trees, local Python environments and downloaded third-party source trees are intentionally excluded from Git.

## Attribution

The banner and documentation for this port use explicit two-line attribution rather than folding both efforts into one author string:

```text
Original project by @Official_I_C_H
WSL2/Linux port by @SpaceDudem
```

See [`NOTICE`](NOTICE) and [`THIRD_PARTY_NOTICES.md`](THIRD_PARTY_NOTICES.md) for upstream and third-party credits.

## Safety / scope

This tooling is intended for research and work on devices you own or are authorized to service. It manipulates low-level Apple boot and recovery interfaces. Understand the command being run before using it on a device containing important data.

The WSL2 port's development workflow modifies disposable RestoreRamDisk build images on the host. It does not require writing to the device's Data volume merely to build the ramdisk.

## License

This repository is MIT licensed. The upstream project's copyright notice is retained, and WSL2/Linux port contributions are additionally attributed here.

Third-party projects, source trees, binaries and payload components remain subject to their respective licenses. See [`NOTICE`](NOTICE) and [`THIRD_PARTY_NOTICES.md`](THIRD_PARTY_NOTICES.md).
