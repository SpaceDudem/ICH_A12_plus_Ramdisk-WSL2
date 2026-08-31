# WSL2/Linux porting notes

This document records the bring-up work required to move `ICH_A12_plus_Ramdisk` from its original macOS/Darwin host assumptions to Windows 11 + WSL2 Linux.

It is intentionally more detailed than the project README. The goal is to preserve the failed approaches, compatibility issues, measurements, and reasons behind the final host-side design so the same work does not have to be rediscovered later.

## Upstream baseline

Upstream project:

- `Pa7r0n/ICH_A12_plus_Ramdisk`
- ICHA12A13 / `new_ramdisk`
- original author/contact: `@Official_I_C_H`

The upstream project is structured around Darwin tooling. Its environment points at `tools/darwin`, and the original RestoreRamDisk workflow uses macOS facilities such as `hdiutil` and `diskutil`.

The WSL2 port keeps the upstream build/boot logic where practical and changes the host-specific pieces instead of replacing the exploit/patchfinder stack.

## Development test target

Current bring-up target:

```text
Device:      iPhone 11
Product:     iPhone12,1
Board:       n104ap
SoC:         A13
CPID:        0x8030
Installed:   iOS 26.0.1
Build:       23A355
DFU exploit: usbliter8
Host:        Windows 11
Guest:       Kali Linux under WSL2
```

Confirmed pwned DFU identity during testing:

```text
CPID: 0x8030
BDID: 0x04
PWND: usbliter8
MODE: DFU
PRODUCT: iPhone12,1
MODEL: n104ap
NAME: iPhone 11
```

## Port architecture

The development environment currently looks like this:

```text
Windows 11
    │
    ├── usbipd-win
    │
    ▼
WSL2 / Kali
    │
    ├── custom WSL kernel
    │    ├── USB core
    │    ├── USB/IP core
    │    ├── vhci-hcd
    │    └── external linux-apfs-rw
    │
    ├── native Linux host tools
    ├── Python virtual environment
    ├── upstream ICH sources
    ├── WSL port orchestration
    └── generated bootchain
             │
             ▼
       Apple DFU / Recovery USB
```

During development, the working tree has used paths similar to:

```text
~/ICH_A12_plus_Ramdisk-wsl2
~/ich-wsl2-port.sh
~/ICH_A12_plus_Ramdisk-wsl2/.local
~/ICH_A12_plus_Ramdisk-wsl2/.wsl-vendor
~/ICH_A12_plus_Ramdisk-wsl2/tools/linux
```

These are development details, not a guarantee of the final installer layout.

## Native Linux toolchain

The port currently verifies the following Linux-side tools:

```text
irecovery
pzb
img4
gtar
trustcache
jq
usbliter8ctl
usbliter8_boot
iproxy
sshpass
ibootim
mkapfs
ipsw
```

### Python environment

Python dependencies are installed into a project-local virtual environment rather than the system Python environment.

The upstream Python requirements include:

```text
pyimg4>=0.8
capstone>=5.0
Pillow>=10.0
```

The Linux wrapper for `usbliter8ctl` also launches its Python implementation through the project virtual environment.

## lzfse / modern CMake compatibility

One of the first native-build failures came from old `lzfse` CMake metadata:

```text
cmake_minimum_required(VERSION 2.8.6)
```

Modern CMake releases reject that policy level by default.

The build was made compatible by configuring the old project with a modern policy floor:

```text
-DCMAKE_POLICY_VERSION_MINIMUM=3.5
```

A second issue was output layout. `img4lib` expected a static archive at a specific path:

```text
lzfse/build/bin/liblzfse.a
```

The Linux build therefore forces a static build and explicit archive/library/runtime output directories so the dependent build can find the expected file.

## ibootim Linux portability

The upstream `ibootim` source assumed the BSD/macOS `EFTYPE` errno value, which is not provided by glibc on Linux.

A small compatibility change was required so the program could compile natively on WSL2 Linux.

This is an example of a recurring porting rule for this repository: host compatibility changes should remain small and isolated rather than modifying unrelated boot logic.

## APFS inside WSL2

### Why APFS became the largest host-side problem

The original project modifies Apple's RestoreRamDisk with macOS-native APFS tools. WSL2 does not provide those facilities.

The port uses the `linux-apfs` ecosystem for host-side RestoreRamDisk work. During development this has included `linux-apfs-rw` and APFS userspace utilities.

The APFS writer is experimental. The port uses it against disposable host-side ramdisk build images, not as an excuse to write arbitrary device Data volumes.

### Custom WSL kernel

The working development kernel is:

```text
6.18.33.2-microsoft-standard-WSL2+
```

A matching `linux-apfs-rw` module was built against that kernel and successfully loaded.

The initial kernel build took far longer than was necessary for normal iteration. Future packaging should avoid requiring every user to perform a multi-hour full-kernel build if a known-good reproducible kernel/module bundle or a more targeted module build can be provided legally and safely.

## USB/IP regression after switching kernels

Once the custom WSL kernel was active, `usbipd-win` could no longer attach USB devices because the corresponding guest USB/IP modules were not installed.

The required development modules included:

```text
usb-common.ko
usbcore.ko
usbip-core.ko
vhci-hcd.ko
```

The dependency failure appeared incrementally:

- `usbip-core` first lacked `usb_speed_string`, fixed by loading/installing `usb-common`
- `vhci-hcd` then lacked USB HCD/core symbols, fixed by loading/installing `usbcore`

After those pieces were present, `usbipd attach --wsl` worked with the custom kernel.

A cleaner final build may compile the needed USB/IP pieces directly into the kernel or package the matching modules together.

## Windows → WSL Apple USB passthrough

Typical Apple USB identities observed during bring-up:

```text
05ac:1227  Apple Mobile Device (DFU Mode)
05ac:1281  Apple Mobile Device (Recovery Mode)
```

Because DFU → Recovery changes the USB identity and causes re-enumeration, Windows may detach the device from WSL during the transition. During development it has sometimes been necessary to:

1. let the phone re-enumerate;
2. inspect the new BUSID with `usbipd list` in PowerShell;
3. attach the Apple device to WSL again;
4. continue the Linux-side workflow.

The final automation should detect and explain this state instead of treating a host re-attach requirement as a mysterious device failure.

## Linux USB permissions

At first, WSL could see the Apple device with `lsusb`, but `irecovery -q` worked only under `sudo`.

A udev rule was added for Apple's vendor ID (`05ac`) and the normal WSL user was placed in the appropriate USB-access group. After re-triggering udev, the Apple device node became accessible without root and `irecovery -q` worked as the normal user.

The installer should handle this explicitly and verify the final device-node permissions.

## RestoreRamDisk: failed reconstruction approach

The first Linux implementation tried to recreate the RestoreRamDisk:

```text
stock Apple APFS image
        ↓
mount read-only
        ↓
create new APFS image
        ↓
copy all logical files
        ↓
inject SSH payload
```

This failed for a non-obvious reason: the compressed/space-efficient Apple APFS image was much smaller than the logical size of the files visible when mounted.

Measurements from the iOS 26.0.1 test build:

```text
Stock image bytes:        197132288
Logical file bytes:       769927773
Allocated logical bytes:  770205696
SSH archive bytes:         11701808
SSH unpacked bytes:        38625718
```

The stock file was only about 188 MiB, while its logical mounted contents were roughly 734 MiB.

The first recreated image ran out of space at roughly 268 MiB.

A 1 GiB reconstruction then succeeded at copying and injecting the filesystem, proving that APFS read/write itself was functional. However, the generated bootchain rejected the result because the ramdisk IMG4 was over 1 GiB while the boot path imposed a limit of roughly 280 MiB.

Conclusion: **rebuilding the Apple filesystem was the wrong strategy even though it technically worked at large size.**

## RestoreRamDisk: direct injection approach

The stock APFS image itself was measured at approximately:

```text
Image size: 197132288 bytes
Used:       ~160 MiB
Available:  ~29 MiB
```

The full upstream SSH payload required roughly 38.6 MiB unpacked, so direct injection of the unmodified payload also failed.

The working strategy became:

```text
stock Apple RestoreRamDisk
        ↓
make disposable working copy
        ↓
mount existing APFS image read/write
        ↓
inject slimmed SSH payload directly
        ↓
unmount
        ↓
wrap original-size image into bootchain
```

This preserves the compact Apple filesystem instead of expanding all of its logical files into a newly created APFS image.

## SSH payload slimming

The largest removable parts of the upstream rescue payload included:

```text
~7.0 MiB  usr/share/misc/magic.mgc
~2.3 MiB  usr/share/locale
~196 KiB  usr/share/nano
          many unused terminfo entries
```

The slim development payload removes the `file` magic database, localization catalogs, nano syntax data, and most terminfo entries while retaining the terminal classes required by the ramdisk environment.

Measured result:

```text
Slim unpacked payload: ~29 MiB
Before injection:      ~29 MiB free
After injection:       ~4.6 MiB free
Final APFS image:      ~188 MiB
Injection result:      SUCCESS
```

The script also preserves a backup and restores the original working image if injection fails.

## Bootchain build status

The iOS 26.0.1 / 23A355 build reached a clean host-side preflight with:

```text
product=iPhone12,1
model=n104ap
cpid=0x8030
chip=A13
version=26.0.1
build=23A355
ibss=0
sptm=0
txm=0
kernel=patched
kpf_set=ios18
with_fw=1
packaging=img4-with-im4m
trustcache=restore-append
```

The `ios18` label is the selected kernel-patch family used by the project for this firmware generation; it does not mean the selected firmware is iOS 18.

Host-side validation passed for the generated DeviceTree, ramdisk, trustcache, kernelcache, iBoot boot arguments, board checks, and patched-kernel mode.

## usbliter8ctl wrapper failure

The first real WSL boot attempt exposed a Linux-wrapper integration bug.

`tools/linux/usbliter8ctl` is a Bash wrapper similar to:

```bash
#!/usr/bin/env bash
set -Eeuo pipefail
exec /path/to/.venv/bin/python /path/to/usbliter8ctl "$@"
```

But `boot.sh` invoked that wrapper as:

```bash
python3 "$USBLITER8CTL" boot "$image"
```

Python therefore attempted to parse the Bash line:

```text
set -Eeuo pipefail
```

and raised a `SyntaxError`.

The boot helper then compounded the problem by treating the failed child process as success and continuing into the Recovery wait loop.

The fix was to execute the wrapper directly and propagate child-process failure rather than hiding it.

After the fix, the host successfully reported:

```text
Loading iBEC (direct, no iBSS)...
usbliter8ctl boot iBoot.patched.bin
sent - 0x2545a0
```

and the device transitioned from pwned DFU to Recovery.

## First successful WSL2 bootchain delivery

After the wrapper fix, WSL2 successfully performed the following sequence:

```text
pwned DFU
  ↓
patched iBoot upload
  ↓
DFU → Recovery re-enumeration
  ↓
Recovery command channel available
  ↓
signed logo upload / setpicture
  ↓
RestoreSEP
  ↓
PMP
  ↓
AOP
  ↓
ANE
  ↓
AVE
  ↓
ISP
  ↓
GFX
  ↓
SIO
  ↓
DeviceTree
  ↓
trustcache
  ↓
ramdisk
  ↓
kernelcache
  ↓
setenvnp boot-args
  ↓
bootx
```

Every host-side upload completed successfully.

## Current blocker: direct-iBEC `bootx` remains in Recovery

The current A13 test reaches `bootx` but does not enter XNU. The screen remains black and the device continues to enumerate as:

```text
05ac:1281 Apple Mobile Device [Recovery Mode]
MODE: Recovery
```

A direct `irecovery -c bootx` retry returns exit code 0 but the device remains in Recovery for subsequent checks.

This is important because it separates the problem from several host-side concerns:

- WSL2 can access the device;
- USB/IP survives or can be re-attached across DFU → Recovery;
- patched iBoot is running;
- the Recovery command channel works;
- all firmware and ramdisk/kernel IMG4 payloads transfer successfully;
- `bootx` reaches iBoot.

There is an upstream macOS report with the same device family and a very similar direct-iBEC symptom: `Pa7r0n/ICH_A12_plus_Ramdisk` issue #4 (`Stuck Recovery after boot.sh`) shows `iPhone12,1 / n104ap / A13`, `ibss=0`, successful payload uploads, and no transition after `bootx`.

That does not prove the root cause is identical, but it demonstrates that the symptom is not unique to WSL2.

## Next validation path: iBSS → iBEC

The next planned test is the alternate bootchain supported by the project:

```text
pwned DFU
  ↓
usbliter8ctl boots patched iBSS
  ↓
iBEC IMG4 loaded via irecovery
  ↓
go
  ↓
Recovery
  ↓
firmware / DeviceTree / trustcache / ramdisk / kernel
  ↓
bootx
```

The build should explicitly produce/stage:

```text
iBSS.patched.bin
iBEC.patched.img4
use-ibss
```

and record `ibss=1` / `use-ibss=1` in the generated chain metadata.

For the first alternate-chain test, display/logo handling should be minimized (`--no-logo`) so the experiment changes only the boot path.

## Recovery timeout behavior

During testing, a device left sitting in iBoot Recovery eventually exited Recovery and booted the installed operating system without an explicit host reset.

This appears consistent with iBoot's autoboot/timeout behavior and should not automatically be interpreted as a kernel panic.

The port should eventually make this distinction clear in its diagnostics.

## What should become reproducible before a release

The development machine now contains enough hand-built state that simply copying the working directory would be a poor release strategy.

A proper release should make these steps deterministic:

1. clone/pin the upstream ICH revision;
2. create a local Python virtual environment;
3. fetch/pin native Linux tool sources;
4. build Linux host utilities;
5. install the Apple udev rule;
6. verify `usbipd-win` prerequisites on Windows;
7. install or build a compatible WSL kernel/module set;
8. load/verify writable APFS support;
9. verify USB/IP guest support;
10. attach and verify Apple DFU USB;
11. verify pwned DFU state;
12. build the bootchain;
13. perform preflight validation;
14. boot while explicitly handling DFU → Recovery re-enumeration;
15. start `iproxy` and verify SSH only after the device has actually reached the ramdisk.

Long-running kernel builds should run directly with output redirected to a log rather than being supervised interactively by an agent or wrapper that repeatedly polls verbose output.

## Packaging direction

The preferred eventual package is a reproducible source-first installer plus optional known-good release artifacts where licensing permits.

Potential release contents:

```text
ich-wsl2-port.sh
setup-usbipd.ps1
udev rule
pinned dependency manifest
checksums
known-good custom WSL kernel or documented build recipe
matching kernel modules if not built-in
native Linux tool wrappers/build scripts
README + PORTING documentation
```

Third-party binaries should not be dumped into a release without preserving their source/license obligations. See `THIRD_PARTY_NOTICES.md`.

## Attribution policy

The upstream project and the WSL2 port should not share an ambiguous combined author line.

Preferred display:

```text
Original project by @Official_I_C_H
WSL2/Linux port by @SpaceDudem
```

The original project's MIT notice and third-party credits remain intact.

## Current definition of success

The WSL2 port should not be called complete merely because `bootx` was sent.

For the current milestone, success requires:

1. reproducible pwned-DFU detection from WSL2;
2. reproducible build of a valid A12/A13 bootchain;
3. device transition through patched iBoot/iBEC;
4. XNU boot into the modified RestoreRamDisk;
5. USB re-enumeration appropriate to the ramdisk environment;
6. `iproxy 2222 22` connectivity;
7. SSH login as root;
8. successful `mount_ich` execution;
9. a clean rebuild/install path that does not depend on undocumented state from the development workstation.

Until those conditions are met, the repository should describe itself as an active WSL2 port / bring-up rather than a finished release.
